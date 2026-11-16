{-# LANGUAGE OverloadedStrings #-}

module Main where
import qualified Minxstr.DatabaseInterface as DB
import Minxstr.Registration
import Minxstr.Configuration
import qualified Minxstr.PKI as PKI
import Network.Wai
import Network.Wai.Handler.WarpTLS
import Network.Wai.Handler.Warp
import Network.HTTP.Types
import Prelude
import System.Exit
import qualified Data.Text as T
import Control.Monad (unless)
import Control.Monad.Extra (unlessM)
import Minxstr.DatabaseInterface (withConnection)


isRegisterRequest :: Method -> String -> Bool
isRegisterRequest method action = method == methodPost && action == "register"

isDeregisterRequest :: Method -> String -> Bool
isDeregisterRequest method action = method == methodPost && action == "deregister"

isPoll :: Method -> String -> Bool
isPoll method action = method == methodGet && action == "poll"

main :: IO ()
main = do
  cfgPath <- resolveConfigPath
  putStrLn $ "[*] Loading configuration from " ++ cfgPath
  cfg <- loadConfiguration cfgPath
  let pkiCfg = pkiConfig cfg
      dbCfg  = databaseConfig cfg

  -- TODO: implement allowances for pre-configured
  unlessM (PKI.isPKIInitialized pkiCfg) (PKI.initPKI pkiCfg)
  failuresList <- PKI.verifyPKI pkiCfg
  unless (null failuresList) (PKI.printAllReasons failuresList >> exitFailure)

  DB.initDatabase dbCfg
  pool <- DB.createConnectionPool dbCfg

  -- maybe this should be the same as whats kept in the cert-store, maybe not
  -- let tlsOpts = mutualTLSSettings (PKI.tlsCertPath pkiCfg) (PKI.tlsKeyPath pkiCfg)
  let tlsOpts = tlsSettings (PKI.tlsCertPath pkiCfg) (PKI.tlsKeyPath pkiCfg)
  let port = serverPort $ serverConfig cfg

  putStrLn $ "[*] Listening on https://localhost:" ++ show port
  runTLS tlsOpts (setPort port defaultSettings) $ app pool

-- introduce pooled connections at some point 
app :: DB.ConnectionPool -> Application
app pool request respond
  | isRegisterRequest method action   = withConnection pool request registerMachine   >>= respond 
  | isDeregisterRequest method action = withConnection pool request deregisterMachine >>= respond 
  | isPoll method action = undefined
  | otherwise = respond $ responseLBS status400 [] ""
  where
    method = requestMethod request
    action = T.unpack $ last $ pathInfo request




-- place holder simple response 
simpleResponse :: Bool -> Response
simpleResponse isSuccess = if isSuccess
                             then responseLBS status200 [] ""
                             else responseLBS status400 [] ""



