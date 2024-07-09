{-# LANGUAGE BangPatterns #-}

module Database.PostgreSQL.Simple.Conduit
    ( query
    , query_
    ) where

import qualified Database.PostgreSQL.LibPQ as LibPQ
import Database.PostgreSQL.Simple (Connection, formatQuery, QueryError (..), ResultError (..))
import Database.PostgreSQL.Simple.ToRow (ToRow)
import Database.PostgreSQL.Simple.FromRow (FromRow, fromRow)
import Database.PostgreSQL.Simple.Internal (RowParser(..), runConversion, throwResultError, withConnection, Row (..))
import Database.PostgreSQL.Simple.Ok (Ok(..), ManyErrors(..))
import Database.PostgreSQL.Simple.TypeInfo (getTypeInfo)
import Database.PostgreSQL.Simple.Types (Query(..))
import Conduit
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C8
import Control.Monad.Reader (runReaderT)
import Control.Monad.State.Strict (runStateT)
import Control.Monad (unless)
import Control.Exception

import Debug.Trace

-- | Perform a @SELECT@ or other SQL query that is expected to return
-- results. All results are retrieved in single-row mode and provided
-- by conduit in constant memory.
--
-- PostgreSQL server may send results in batches, and libpq allocates
-- space for the whole batch.
--
-- Exceptions that may be thrown:
--
-- * 'FormatError': the query string could not be formatted correctly.
--
-- * 'QueryError': the result contains no columns (i.e. you should be
--   using 'execute' instead of 'query').
--
-- * 'ResultError': result conversion failed.
--
-- * 'SqlError':  the postgresql backend returned an error,  e.g.
--   a syntax or type error,  or an incorrect table or column name.
query :: (MonadResource m, ToRow qps, FromRow r) => Connection -> Query -> qps -> ConduitT () r m ()
query conn q ps = do
  pid <- liftIO $ withConnection conn LibPQ.backendPID
  traceM $ "query (" ++ show pid ++ ") " ++ show q
  fq <- liftIO (formatQuery conn q ps)
  doQuery fromRow conn q fq

-- | A version of 'query' that does not perform query substitution.
query_ :: (MonadResource m, FromRow r) => Connection -> Query -> ConduitT () r m ()
query_ conn q = do
    pid <- liftIO $ withConnection conn LibPQ.backendPID
    traceM ("query_ (" ++ show pid ++ ") " ++ show q)
    doQuery fromRow conn q (fromQuery q)

doQuery :: (MonadResource m) => RowParser r -> Connection -> Query -> B.ByteString -> ConduitT () r m ()
doQuery parser conn q fq = bracketP (withConnection conn initQ)
             (\_ -> cancelQuery conn)
             (\_ -> yieldResults parser conn q)
  where
    initQ c = do
      pid <- LibPQ.backendPID c
      traceM $ "Initializing query at " ++ show pid
      LibPQ.sendQuery c fq >>= flip unless (throwConnError c pid)
      traceM $ "Initializing connection at " ++ show pid ++ " to single row mode"
      LibPQ.setSingleRowMode c >>= flip unless (throwConnError c pid)
      traceM $ "Initialization at " ++ show pid ++ " is finished"
    throwConnError c pid = do
      e <- LibPQ.errorMessage c
      case e of
        Nothing -> throwM $ QueryError "No error" q
        Just msg -> throwM $ QueryError ("PID: (" ++ show pid ++ ") " ++ C8.unpack msg) q

yieldResults :: (MonadResource m) => RowParser r -> Connection -> Query -> ConduitT () r m ()
yieldResults parser conn q = do
  mres <- liftIO $ withConnection conn LibPQ.getResult
  case mres of
    Nothing -> pure ()
    Just result -> do
      pid <- liftIO $ withConnection conn LibPQ.backendPID
      status <- liftIO $ LibPQ.resultStatus result
      case status of
        LibPQ.EmptyQuery -> liftIO $ throwM $ QueryError ("query (" ++ show pid ++ "): Empty query") q
        LibPQ.CommandOk -> liftIO $ throwM $ QueryError ("query (" ++ show pid ++ ") resulted in a command response") q
        LibPQ.CopyOut -> liftIO $ throwM $ QueryError ("query (" ++ show pid ++ "): COPY TO is not supported") q
        LibPQ.CopyIn -> liftIO $ throwM $ QueryError ("query (" ++ show pid ++ "): COPY FROM is not supported") q
        LibPQ.BadResponse -> liftIO $ throwResultError (C8.pack $ "query (" ++ show pid ++ ")") result status
        LibPQ.NonfatalError -> liftIO $ throwResultError (C8.pack $ "query (" ++ show pid ++ ")") result status
        LibPQ.FatalError -> liftIO $ throwResultError (C8.pack $ "query (" ++ show pid ++ ")") result status
        LibPQ.SingleTuple -> yieldResult parser conn result q
        LibPQ.TuplesOk -> liftIO $ finishQuery conn
        _ -> liftIO $ throwM $ QueryError ("query (" ++ show pid ++ "): unknown error") q

yieldResult :: (MonadResource m) => RowParser r -> Connection -> LibPQ.Result -> Query -> ConduitT () r m ()
yieldResult parser conn result q = do
  ncols <- liftIO (LibPQ.nfields result)
  r <- liftIO $ onException (getRowWith parser ncols conn result)
                            (traceM "onException cleanup." >> cancelQuery conn)
  yield r
  yieldResults parser conn q

-- | Taken from Database.PostgreSQL.Simple
getRowWith :: RowParser r -> LibPQ.Column -> Connection -> LibPQ.Result -> IO r
getRowWith parser ncols conn result = do
  let rw = Row 0 result
  let unCol (LibPQ.Col x) = fromIntegral x :: Int
  okvc <- runConversion (runStateT (runReaderT (unRP parser) rw) 0) conn
  case okvc of
    Ok (val, col)
      | col == ncols -> return val
      | otherwise -> do
        vals <-
          forM' 0 (ncols - 1) $ \c -> do
            tinfo <- getTypeInfo conn =<< LibPQ.ftype result c
            v <- LibPQ.getvalue result 0 c
            return (tinfo, fmap ellipsis v)
        throwM
          (ConversionFailed
             (show (unCol ncols) ++ " values: " ++ show vals)
             Nothing
             ""
             (show (unCol col) ++ " slots in target type")
             "mismatch between number of columns to convert and number in target type")
    Errors [] -> throwM $ ConversionFailed "" Nothing "" "" "unknown error"
    Errors [x] -> throwM x
    Errors xs -> throwM $ ManyErrors xs

shutdownQuery :: Connection -> IO ()
shutdownQuery conn = do
  s <- withConnection conn LibPQ.transactionStatus
  case s of
    LibPQ.TransActive -> cancelQuery conn
    _ -> return ()

cancelQuery :: Connection -> IO ()
cancelQuery conn = do
  pid <- withConnection conn LibPQ.backendPID
  traceM $ "Cancelling query at " ++ show pid
  status <- withConnection conn LibPQ.status
  case status of
    LibPQ.ConnectionBad -> traceM ("Not cleaning up " ++ show pid ++ " because the connection is bad")
    cs -> do
      traceM ("Cleaning up " ++ show pid ++ " with status '" ++ show cs ++ "'")
      c <- withConnection conn LibPQ.getCancel
      case c of
        Just c' -> do
          traceM "Got cancel data"
          r <- LibPQ.cancel c'
          case r of
            Left _ -> return ()
            Right _ -> finishQuery conn
        Nothing -> traceM "Got no cancel data"

finishQuery :: Connection -> IO ()
finishQuery conn = do
  r <- withConnection conn LibPQ.getResult
  case r of
    Just _ -> finishQuery conn
    Nothing -> return ()

-- Taken from Database.PostgreSQL.Simple
forM' :: (Ord n, Num n) => n -> n -> (n -> IO a) -> IO [a]
forM' lo hi m = loop hi []
  where
    loop !n !as
      | n < lo = return as
      | otherwise = do
        a <- m n
        loop (n-1) (a:as)
{-# INLINE forM' #-}

-- | Taken from Database.PostgreSQL.Simple
ellipsis :: B.ByteString -> B.ByteString
ellipsis bs
  | B.length bs > 15 = B.take 10 bs `B.append` "[...]"
  | otherwise        = bs
