module Main where
import Minxstr.PKI
import Minxstr.Configuration
import Control.Monad (when)
import System.Directory (removePathForcibly)
import System.Exit (exitSuccess, exitFailure)

-- runs against a throwaway cert store so the test never clobbers the
-- dev server's ./cert-store
testPKIConfig :: PKIConfig
testPKIConfig = (pkiConfig defaultConfiguration)
  { pkiCertStoreDir = "./dist-newstyle/test-cert-store" }

main :: IO ()
main = do
  removePathForcibly (pkiCertStoreDir testPKIConfig)

  initialized <- isPKIInitialized testPKIConfig
  when initialized (putStrLn "[!] Cert store should start empty" >> exitFailure)

  initPKI testPKIConfig

  initializedAfter <- isPKIInitialized testPKIConfig
  when (not initializedAfter) (putStrLn "[!] Cert store empty after initPKI" >> exitFailure)

  reasons <- verifyPKI testPKIConfig
  when (null reasons) (putStrLn "[*] Validation completed, all checks passed" >> exitSuccess)
  printAllReasons reasons
  exitFailure
