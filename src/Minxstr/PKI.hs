module Minxstr.PKI where

import System.Process (callProcess)
import System.FilePath ((</>))
import Data.X509
import Data.X509.Validation
import Data.X509.CertificateStore
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory)
import qualified Data.ByteString as BS
import Data.X509.File (readSignedObject)
import Data.Foldable (for_)
import Minxstr.Configuration (PKIConfig (..))

----
---- cert-store layout, all relative to the configured cert_store_dir
----
tlsPKIDir :: PKIConfig -> FilePath
tlsPKIDir cfg = pkiCertStoreDir cfg </> "transport"

rootCertPath :: PKIConfig -> FilePath
rootCertPath cfg = pkiCertStoreDir cfg </> "root-crt.pem"

rootKeyPath :: PKIConfig -> FilePath
rootKeyPath cfg = pkiCertStoreDir cfg </> "root-key.pem"

tlsCertPath :: PKIConfig -> FilePath
tlsCertPath cfg = tlsPKIDir cfg </> "tls-crt.pem"

tlsKeyPath :: PKIConfig -> FilePath
tlsKeyPath cfg = tlsPKIDir cfg </> "tls-key.pem"

tlsCSRPath :: PKIConfig -> FilePath
tlsCSRPath cfg = tlsPKIDir cfg </> "tls-csr.pem"

----
---- certificate subjects
---- (passed straight to openssl via callProcess, so no shell quoting needed)
----
rootSubject :: String
rootSubject = "/C=/ST=/L=/O=/CN=Minxstr"

tlsSubject :: PKIConfig -> String
tlsSubject cfg = "/C=/ST=/L=/O=/CN=" ++ pkiCommonName cfg

tlsSAN :: PKIConfig -> String
tlsSAN cfg = "subjectAltName=DNS:" ++ cn ++ ",DNS:www." ++ cn
  where cn = pkiCommonName cfg

----
---- openssl wrappers
---- callProcess execs openssl directly (no /bin/sh), so paths from the
---- config file can contain spaces etc. without being split or interpreted
----
type CurveType = String

createECKey :: CurveType -> FilePath -> IO ()
createECKey curve path = callProcess "openssl"
  ["ecparam", "-name", curve, "-genkey", "-noout", "-out", path]

createSelfSignedCert :: Int -> FilePath -> FilePath -> IO ()
createSelfSignedCert validityDays inputKeyPath outputCertPath = callProcess "openssl"
  [ "req", "-x509", "-new", "-noenc", "-sha256"
  , "-days", show validityDays
  , "-key",  inputKeyPath
  , "-out",  outputCertPath
  , "-subj", rootSubject
  ]

createTLSCSR :: PKIConfig -> FilePath -> FilePath -> IO ()
createTLSCSR cfg inputKeyPath outputCSRPath = callProcess "openssl"
  [ "req", "-new"
  , "-key",    inputKeyPath
  , "-out",    outputCSRPath
  , "-subj",   tlsSubject cfg
  , "-addext", tlsSAN cfg
  ]

signTLSCSR :: Int -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
signTLSCSR validityDays inputCSRPath outputCertPath inputRootKeyPath inputRootCertPath = callProcess "openssl"
  [ "x509", "-req"
  , "-in",    inputCSRPath
  , "-CA",    inputRootCertPath
  , "-CAkey", inputRootKeyPath
  , "-out",   outputCertPath
  , "-days",  show validityDays
  , "-sha256"
  -- `openssl x509 -req` drops CSR extensions (i.e. the SAN) unless told to keep them
  , "-copy_extensions", "copy"
  ]

-- a cert store counts as initialized once it exists and has something in it.
-- checking existence first matters under systemd: on first boot the state
-- directory is empty and cert_store_dir doesn't exist yet
isPKIInitialized :: PKIConfig -> IO Bool
isPKIInitialized cfg = do
  exists <- doesDirectoryExist (pkiCertStoreDir cfg)
  if not exists then return False
  else not . null <$> listDirectory (pkiCertStoreDir cfg)

-- TODO: error handling when im not a lazy fucking chud
-- PKI not provided
initPKI :: PKIConfig -> IO ()
initPKI cfg = do
  createDirectoryIfMissing True (tlsPKIDir cfg)

  createECKey          (pkiCurve cfg) (rootKeyPath cfg)
  createSelfSignedCert (pkiRootCertValidityDays cfg) (rootKeyPath cfg) (rootCertPath cfg)

  createECKey  (pkiCurve cfg) (tlsKeyPath cfg)
  createTLSCSR cfg            (tlsKeyPath cfg) (tlsCSRPath cfg)
  signTLSCSR   (pkiTlsCertValidityDays cfg)
               (tlsCSRPath cfg) (tlsCertPath cfg) (rootKeyPath cfg) (rootCertPath cfg)


-- validates the TLS cert against the cert store, using the configured
-- common name as the service identity
verifyPKI :: PKIConfig -> IO [FailedReason]
verifyPKI cfg = do
  certStoreMaybe <- readCertificateStore (pkiCertStoreDir cfg)
  certStore      <- case certStoreMaybe of
                      Just cs -> return cs
                      Nothing -> error $ "[!] Unable to parse or find certs in " ++ pkiCertStoreDir cfg
  cert           <- CertificateChain <$> readSignedObject (tlsCertPath cfg)

  validate HashSHA256
           defaultHooks
           defaultChecks
           certStore
           defaultValidationCache
           (pkiCommonName cfg, BS.empty)
           cert


printReasons :: FailedReason -> IO ()
printReasons reason = putStrLn $ "[!] Check failed: " ++ (show reason)

printAllReasons :: [FailedReason] -> IO ()
printAllReasons reasons = for_ reasons printReasons
