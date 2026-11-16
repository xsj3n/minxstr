{-# LANGUAGE OverloadedStrings #-}
-- this file is claude slop bc i didnt want to write ts 
module Minxstr.Configuration
  ( MinxstrConfiguration (..)
  , ServerConfig (..)
  , DatabaseConfig (..)
  , PKIConfig (..)
  , defaultConfiguration
  , loadConfiguration
  , resolveConfigPath
  ) where

import System.Environment (getArgs, lookupEnv)

import qualified Toml
import Toml (TomlCodec, (.=))
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import System.Directory (doesFileExist)

data ServerConfig = ServerConfig
  { serverPort :: Int
  } deriving (Eq, Show)

data DatabaseConfig = DatabaseConfig
  { databaseHost :: String
  , databaseUser :: String
  , databasePort :: Int
  , databaseName :: String
  , databasePoolSize :: Int
  } deriving (Eq, Show)

data PKIConfig = PKIConfig
  { pkiCertStoreDir         :: FilePath
  , pkiCommonName           :: String
  , pkiCurve                :: String
  , pkiRootCertValidityDays :: Int
  , pkiTlsCertValidityDays  :: Int
  } deriving (Eq, Show)

data MinxstrConfiguration = MinxstrConfiguration
  { serverConfig   :: ServerConfig
  , databaseConfig :: DatabaseConfig
  , pkiConfig      :: PKIConfig
  } deriving (Eq, Show)

-- what's already hardcoded elsewhere today, kept here as the fallback
-- for whatever a config file leaves unset
defaultConfiguration :: MinxstrConfiguration
defaultConfiguration = MinxstrConfiguration
  { serverConfig = ServerConfig
      { serverPort = 3000
      }
  , databaseConfig = DatabaseConfig
      { databaseHost = "localhost"
      , databaseUser = "xs"
      , databasePort = 5432
      , databaseName = "managed"
      , databasePoolSize = 20
      }
  , pkiConfig = PKIConfig
      { pkiCertStoreDir         = "./cert-store/"
      , pkiCommonName           = "Minxstr.local"
      , pkiCurve                = "prime256v1"
      , pkiRootCertValidityDays = 3650
      , pkiTlsCertValidityDays  = 360
      }
  }

-- mirrors MinxstrConfiguration field-for-field, but every field optional,
-- so an admin's config file only has to mention what it wants to override
data PartialServerConfig = PartialServerConfig
  { partialServerPort :: Maybe Int
  }

data PartialDatabaseConfig = PartialDatabaseConfig
  { partialDatabaseHost :: Maybe String
  , partialDatabaseUser :: Maybe String
  , partialDatabasePort :: Maybe Int
  , partialDatabaseName :: Maybe String
  , partialDatabasePoolSize :: Maybe Int
  }

data PartialPKIConfig = PartialPKIConfig
  { partialPkiCertStoreDir         :: Maybe FilePath
  , partialPkiCommonName           :: Maybe String
  , partialPkiCurve                :: Maybe String
  , partialPkiRootCertValidityDays :: Maybe Int
  , partialPkiTlsCertValidityDays  :: Maybe Int
  }

data PartialConfiguration = PartialConfiguration
  { partialServerConfig   :: PartialServerConfig
  , partialDatabaseConfig :: PartialDatabaseConfig
  , partialPkiConfig      :: PartialPKIConfig
  }

serverCodec :: TomlCodec PartialServerConfig
serverCodec = PartialServerConfig
  <$> Toml.dioptional (Toml.int "port") .= partialServerPort

databaseCodec :: TomlCodec PartialDatabaseConfig
databaseCodec = PartialDatabaseConfig
  <$> Toml.dioptional (Toml.string "host") .= partialDatabaseHost
  <*> Toml.dioptional (Toml.string "user") .= partialDatabaseUser
  <*> Toml.dioptional (Toml.int    "port") .= partialDatabasePort
  <*> Toml.dioptional (Toml.string "name") .= partialDatabaseName
  <*> Toml.dioptional (Toml.int    "pool_size") .= partialDatabasePoolSize

pkiCodec :: TomlCodec PartialPKIConfig
pkiCodec = PartialPKIConfig
  <$> Toml.dioptional (Toml.string "cert_store_dir")          .= partialPkiCertStoreDir
  <*> Toml.dioptional (Toml.string "common_name")             .= partialPkiCommonName
  <*> Toml.dioptional (Toml.string "curve")                   .= partialPkiCurve
  <*> Toml.dioptional (Toml.int    "root_cert_validity_days") .= partialPkiRootCertValidityDays
  <*> Toml.dioptional (Toml.int    "tls_cert_validity_days")  .= partialPkiTlsCertValidityDays

configCodec :: TomlCodec PartialConfiguration
configCodec = PartialConfiguration
  <$> Toml.table serverCodec   "server"   .= partialServerConfig
  <*> Toml.table databaseCodec "database" .= partialDatabaseConfig
  <*> Toml.table pkiCodec      "pki"      .= partialPkiConfig

applyDefaults :: PartialConfiguration -> MinxstrConfiguration
applyDefaults partial = MinxstrConfiguration
  { serverConfig = ServerConfig
      { serverPort = fromMaybe (serverPort defServer) (partialServerPort partServer)
      }
  , databaseConfig = DatabaseConfig
      { databaseHost = fromMaybe (databaseHost defDatabase) (partialDatabaseHost partDatabase)
      , databaseUser = fromMaybe (databaseUser defDatabase) (partialDatabaseUser partDatabase)
      , databasePort = fromMaybe (databasePort defDatabase) (partialDatabasePort partDatabase)
      , databaseName = fromMaybe (databaseName defDatabase) (partialDatabaseName partDatabase)
      , databasePoolSize = fromMaybe (databasePoolSize defDatabase) (partialDatabasePoolSize partDatabase)
      }
  , pkiConfig = PKIConfig
      { pkiCertStoreDir         = fromMaybe (pkiCertStoreDir defPki) (partialPkiCertStoreDir partPki)
      , pkiCommonName           = fromMaybe (pkiCommonName defPki) (partialPkiCommonName partPki)
      , pkiCurve                = fromMaybe (pkiCurve defPki) (partialPkiCurve partPki)
      , pkiRootCertValidityDays = fromMaybe (pkiRootCertValidityDays defPki) (partialPkiRootCertValidityDays partPki)
      , pkiTlsCertValidityDays  = fromMaybe (pkiTlsCertValidityDays defPki) (partialPkiTlsCertValidityDays partPki)
      }
  }
  where
    defServer   = serverConfig defaultConfiguration
    partServer  = partialServerConfig partial
    defDatabase = databaseConfig defaultConfiguration
    partDatabase = partialDatabaseConfig partial
    defPki      = pkiConfig defaultConfiguration
    partPki     = partialPkiConfig partial

-- where to look for the config file, in priority order:
--   1. `--config PATH` on the command line (what the systemd unit passes)
--   2. the MINXSTR_CONFIG environment variable
--   3. ./config.toml (the dev-shell default)
resolveConfigPath :: IO FilePath
resolveConfigPath = do
  args   <- getArgs
  envVar <- lookupEnv "MINXSTR_CONFIG"
  return $ case (flagValue args, envVar) of
    (Just path, _)       -> path
    (Nothing, Just path) -> path
    (Nothing, Nothing)   -> "./config.toml"
  where
    flagValue ("--config" : path : _) = Just path
    flagValue (_ : rest)              = flagValue rest
    flagValue []                      = Nothing

loadConfiguration :: FilePath -> IO MinxstrConfiguration
loadConfiguration path = do
  exists <- doesFileExist path
  if not exists
    then return defaultConfiguration
    else do
      result <- Toml.decodeFileEither configCodec path
      case result of
        Right partial -> return $ applyDefaults partial
        Left errs     -> error $ "[!] Failed to parse config file " ++ path ++ ":\n"
                               ++ T.unpack (Toml.prettyTomlDecodeErrors errs)
