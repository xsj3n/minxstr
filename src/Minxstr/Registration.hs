{-# LANGUAGE OverloadedStrings #-}
module Minxstr.Registration where 
import Network.Wai (Request (requestBodyLength), getRequestBodyChunk, RequestBodyLength (ChunkedBody, KnownLength), strictRequestBody)
import Database.PostgreSQL.Simple (Connection, execute)
import Minxstr.DataSchema (NixMachine (machineID), NixMachineEnrollment (enrollmentToken, machineDetails), expiresAt, TokenValidityInfo (revokedAt, usedAt))
import Minxstr.DatabaseInterface (insertToken, getTokenInfo, DatabaseConnection (dbConn), insertMachine, deleteMachineRecord)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Control.Monad (void, when)
import Data.Aeson (decode)
import Data.ByteArray.Encoding (convertToBase, Base (Base16))
import Data.Maybe
import System.IO (openFile, IOMode (WriteMode), hClose)
import Crypto.Hash (Digest, hash)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteArray as BA
import Data.Time (getCurrentTime)
import qualified Data.List.NonEmpty as NE
import Control.Exception (throwIO, Exception)
import Data.Aeson.Types (FromJSON)


data RegistrationStatus = MalformedRequest | DatabaseOverAffected | DatabaseAffectFailure | TokenValidationFailure | OperationSuccess 
  deriving Show
  
data ManagementStatusUpdate = Create | Delete
  deriving (Eq, Show)

registerMachine :: Request -> DatabaseConnection -> IO RegistrationStatus
registerMachine request conn = do
  maybeNixMachine       <- (decodeBody request :: IO (Maybe NixMachineEnrollment))
  if isNothing maybeNixMachine then return MalformedRequest
  else do
    let enrNixMachine = fromJust maybeNixMachine
        tokenHash  = hash $ BSC.pack $ enrollmentToken enrNixMachine :: Digest SHA256

    isValidated <- handleTokenValidation (dbConn conn) $ BA.convert tokenHash
    if isValidated then updateManagementStatus conn (machineDetails enrNixMachine) Create 
    else return TokenValidationFailure 
   

deregisterMachine :: Request -> DatabaseConnection -> IO RegistrationStatus
deregisterMachine request conn = do
  maybeNixMachine <- (decodeBody request :: IO (Maybe NixMachine))
  if isNothing maybeNixMachine then return MalformedRequest 
  else updateManagementStatus conn (fromJust maybeNixMachine) Delete

updateManagementStatus :: DatabaseConnection -> NixMachine -> ManagementStatusUpdate -> IO RegistrationStatus
updateManagementStatus conn nixMachine action
  | action == Delete = do
    affected <- deleteMachineRecord (dbConn conn) $ machineID nixMachine
    if      affected == 0 then return DatabaseAffectFailure
    else if affected > 1  then return DatabaseOverAffected
    else return OperationSuccess

  | action == Create = do
    affected <- insertMachine conn nixMachine
    if      affected == 0 then return DatabaseAffectFailure
    else if affected > 1  then return DatabaseOverAffected
    else return OperationSuccess 
   


decodeBody :: (FromJSON a) => Request -> IO (Maybe a)
decodeBody request = do
  let len = case requestBodyLength request of 
              ChunkedBody   -> 0
              KnownLength l -> l
  if len > 4028 || len == 0 then return Nothing
  else do
    body <- strictRequestBody request
    case (decode body) of
      Nothing -> return Nothing
      Just n  -> return $ Just n 



-- token stuff 
handleTokenValidation :: Connection -> BS.ByteString -> IO Bool
handleTokenValidation conn tokenHash = do
  tokenInfoM   <- getTokenInfo conn tokenHash >>= return . NE.nonEmpty 
  if isNothing tokenInfoM then return False
  else do
    let tokenInfo = NE.head $ fromJust tokenInfoM
    currentTime <- getCurrentTime
    if (expiresAt tokenInfo < currentTime) ||
       (isJust $ revokedAt tokenInfo)      ||
       (isJust $ usedAt tokenInfo)
    then return False
    else return True 


generateToken :: Connection -> IO (BS.ByteString, String)
generateToken conn = do
  randBytes <- getRandomBytes 48 :: IO BS.ByteString
  let token          = "enr_" <> (convertToBase Base16 randBytes :: BS.ByteString)
      tokenHash      = BA.convert (hash token :: Digest SHA256)
  insertToken conn tokenHash
  return (tokenHash, BSC.unpack token)
