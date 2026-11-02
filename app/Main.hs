{-# LANGUAGE OverloadedStrings #-}

module Main where
import qualified Navix.DatabaseInterface as DB
import Navix.Registration
import Navix.Configuration
import qualified Navix.PKI as PKI
import Network.Wai
import Network.Wai.Handler.WarpTLS
import Network.Wai.Handler.Warp
import Network.HTTP.Types
import Prelude
import System.Exit
import qualified Data.Text as T
import Control.Monad (unless)
import System.Directory.Extra (listFiles)
import Control.Monad.Extra (whenM)
import Navix.DatabaseInterface (withConnection)


isRegisterRequest :: Method -> String -> Bool
isRegisterRequest method action = method == methodPost && action == "register"

isDeregisterRequest :: Method -> String -> Bool
isDeregisterRequest method action = method == methodPost && action == "deregister"

isPoll :: Method -> String -> Bool
isPoll method action = method == methodGet && action == "poll"

main :: IO ()
main = do
  cfg <- loadConfiguration "./config.toml"  
  -- TODO: implement allowances for pre-configured
  whenM (null <$> listFiles PKI.certStoreDir) PKI.initPKI  
  failuresList <- PKI.verifyPKI "Navix.local" 
  unless (null failuresList) (PKI.printAllReasons failuresList >> exitFailure)   
  pool <- DB.createConnectionPool 20
  
  -- maybe this should be the same as whats kept in the cert-store, maybe not
  -- let tlsOpts = mutualTLSSettings PKI.tlsCertPath PKI.tlsKeyPath
  let tlsOpts = tlsSettings PKI.tlsCertPath PKI.tlsKeyPath
  let port = 3000

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



