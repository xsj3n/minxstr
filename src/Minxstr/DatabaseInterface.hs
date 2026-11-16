{-# LANGUAGE OverloadedStrings #-}

module Minxstr.DatabaseInterface
  ( ConnectionPool
  , ConnectionType
  , DatabaseConnection
  , deleteMachineRecord
  , withConnection
  , dbConn
  , createConnectionPool
  , consumeToken
  , insertMachine 
  , getTokenInfo
  , insertToken
  , initDatabase
  , connectInfoFromConfig
  ) where
import Minxstr.Configuration (DatabaseConfig (..))
import Minxstr.Queries
import Minxstr.DataSchema (NixMachine (NixMachine), TokenValidityInfo (TokenValidityInfo))
import Data.Typeable
import Database.PostgreSQL.Simple
import Data.String.Interpolate
import Data.String (fromString)
import Data.Int (Int64)
import Control.Monad (void, unless)
import Generic.Data (gdatatypeName)
import System.Directory.Extra (listDirectories)
import Data.List.Extra (splitOn, trim)
import Data.Foldable (for_)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Crypto.Hash (Digest)
import Data.ByteString (ByteString)
import Data.Time (UTCTime)
import Control.Monad.State.Strict (runState, State, MonadState (put, get), StateT (runStateT), MonadIO (liftIO), evalStateT)
import Control.Monad.Extra (replicateM)
import GHC.Conc (TVar)
import GHC.Conc.Sync (newTVarIO)
import Network.Wai (Request, Response, responseLBS, ResponseReceived)
import Control.Concurrent.STM (modifyTVar')
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM (readTVar)
import Control.Concurrent.STM (writeTVar)
import Control.Concurrent.STM (retry)
import Control.Exception (bracket)
import Control.Monad.Catch (generalBracket, ExitCase (ExitCaseAbort, ExitCaseException, ExitCaseSuccess))
import Network.HTTP.Types (status200)
import Network.HTTP.Types.Status (status500)
import Network.HTTP.Types (status300)
import Control.Exception.Base (throwIO)
import Control.Exception (throw)



----
---- connection management
----
newtype ConnectionPool = ConnectionPool (TVar [DatabaseConnection])
data ConnectionType = Privileged | Unprivileged 
data DatabaseConnection = DatabaseConnection
  { id       :: Int
  , dbConn     :: Connection
  , dbConnType :: ConnectionType 
  }

getConnection :: DatabaseConfig -> Int -> IO DatabaseConnection
getConnection cfg id = do
  dbConn <- connect $ connectInfoFromConfig cfg
  return DatabaseConnection {id = id, dbConn = dbConn, dbConnType = Unprivileged }

poolBuilder :: DatabaseConfig -> StateT Int IO (DatabaseConnection)
poolBuilder cfg = do
  count <- get
  con   <- liftIO (getConnection cfg count)
  put $ count + 1
  return con

createConnectionPool :: DatabaseConfig -> IO ConnectionPool
createConnectionPool cfg = do
  conns <- evalStateT (replicateM (databasePoolSize cfg) (poolBuilder cfg)) 0
  ConnectionPool <$> newTVarIO conns

withConnection :: ConnectionPool -> Request -> (Request -> DatabaseConnection -> IO a) -> IO Response
withConnection (ConnectionPool var) request action  = do
  (_, r) <- generalBracket acquire release (action request) 
  return r 
  where
    acquire = atomically $ do
      conns <- readTVar var
      case conns of
        []     -> retry
        c:cs -> writeTVar var cs >> return c
        
    release c exitCase = case exitCase of
        ExitCaseSuccess _   -> endTransaction True c  >> (atomically $ modifyTVar' var (c :))  >> (return $ responseLBS status200 [] "") 
        ExitCaseException _ -> endTransaction False c >> (atomically $ modifyTVar' var (c :))  >> (return $ responseLBS status300 [] "")
        ExitCaseAbort       -> endTransaction False c >> (atomically $ modifyTVar' var (c :))  >> (return $ responseLBS status500 [] "")
      


  
-- host may be a hostname/IP (TCP) or an absolute directory path, in which case
-- libpq connects over the unix socket in that directory (e.g. /run/postgresql
-- on NixOS, which allows passwordless peer auth as the service's OS user)
connectInfoFromConfig :: DatabaseConfig -> ConnectInfo
connectInfoFromConfig cfg = defaultConnectInfo
  { connectHost     = databaseHost cfg
  , connectDatabase = databaseName cfg
  , connectUser     = databaseUser cfg
  , connectPort     = fromIntegral $ databasePort cfg
  }


-- makes sure the schema exists. the database itself is expected to already
-- exist (created by the NixOS module via ensureDatabases, or by hand in dev);
-- every statement in the schema file is `if not exists`, so this is safe to
-- run on every startup
initDatabase :: DatabaseConfig -> IO ()
initDatabase cfg = bracket (connect $ connectInfoFromConfig cfg) close $ \conn -> do
  putStrLn $ "[*] Ensuring schema exists in database " ++ databaseName cfg
  withTransaction conn $ mapM_ (execute_ conn) schemaQueries

----
---- general info fetching
----

getMachineRecord :: Connection -> String -> IO [NixMachine]
getMachineRecord conn name = query conn getMachineByDeviceNameQuery $ Only name

----
---- enrollment token related
----
insertToken :: Connection -> ByteString  -> IO Int64
insertToken conn tokenHash = execute conn insertTokenQuery $ Only $ Binary tokenHash

getTokenInfo :: Connection -> ByteString -> IO [TokenValidityInfo]
getTokenInfo conn tokenHash = query conn getTokenValidationInfoQuery $ Only $ Binary tokenHash

consumeToken :: Connection -> ByteString -> IO Int64
consumeToken conn tokenHash = execute conn consumeTokenQuery $ Only $ Binary tokenHash

----
---- registration related
----
deleteMachineRecord :: Connection -> Int64 -> IO Int64
deleteMachineRecord conn id = execute conn deregisterQuery $ Only id

insertMachine :: DatabaseConnection -> NixMachine -> IO Int64
insertMachine conn nixMachine = execute (dbConn conn) registerQuery nixMachine

----
---- sql query function helpers 
----
runQueries_ :: DatabaseConnection -> [Query] -> IO Int64
runQueries_ con queries = sum <$> mapM (execute_ $ dbConn con) queries 

-- transaction wrappers, may use them, but only if i need to use these within other modules,
-- which, to be fair, i shouldnt 
beginTransaction :: DatabaseConnection -> IO ()
beginTransaction con = begin $ dbConn con

endTransaction :: Bool -> DatabaseConnection -> IO ()
endTransaction isOkay con
  | isOkay == True  = commit $ dbConn con 
  | isOkay == False = rollback $ dbConn con


