{-# LANGUAGE TemplateHaskell #-}
module Minxstr.Queries
  ( schemaQueries
  , splitQueries
  , getMachineByDeviceNameQuery
  , insertTokenQuery
  , getTokenValidationInfoQuery
  , consumeTokenQuery
  , registerQuery
  , deregisterQuery
  ) where

import Data.FileEmbed (embedStringFile)
import Data.List.Extra (splitOn, trim)
import Data.String (fromString)
import Database.PostgreSQL.Simple (Query)

schemaQueries :: [Query]
schemaQueries = splitQueries $(embedStringFile "queries/init/table-creation.sql")

splitQueries :: String -> [Query]
splitQueries = fmap fromString . filter (not . null) . fmap trim . splitOn "--"

getMachineByDeviceNameQuery :: Query
getMachineByDeviceNameQuery = $(embedStringFile "queries/fetch/get-machine-by-device-name.sql")

insertTokenQuery :: Query
insertTokenQuery = $(embedStringFile "queries/registration/insert-token.sql")

getTokenValidationInfoQuery :: Query
getTokenValidationInfoQuery = $(embedStringFile "queries/registration/get-token-validation-info.sql")

consumeTokenQuery :: Query
consumeTokenQuery = $(embedStringFile "queries/registration/consume-token.sql")

registerQuery :: Query
registerQuery = $(embedStringFile "queries/registration/register.sql")

deregisterQuery :: Query
deregisterQuery = $(embedStringFile "queries/registration/deregister.sql")
