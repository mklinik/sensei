{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
module Language.Haskell.GhciWrapper (
  Config(..)
, Interpreter(echo)
, withInterpreter
, eval
, evalVerbose
) where

import           Imports

import qualified Data.ByteString as B
import           Data.Text.Encoding (decodeUtf8)
import qualified Data.Text as T
import           System.IO hiding (stdin, stdout, stderr)
import           System.Directory (doesFileExist, makeAbsolute)
import           System.Environment (getEnvironment)
import           System.Process
import           System.Exit (ExitCode(..))

import qualified ReadHandle
import           ReadHandle (ReadHandle, toReadHandle)

data Config = Config {
  configIgnoreDotGhci :: Bool
, configStartupFile :: FilePath
, configWorkingDirectory :: Maybe FilePath
, configEcho :: ByteString -> IO ()
}

data Interpreter = Interpreter {
  hIn  :: Handle
, hOut :: Handle
, readHandle :: ReadHandle
, process :: ProcessHandle
, echo :: ByteString -> IO ()
}

die :: String -> IO a
die = throwIO . ErrorCall

withInterpreter :: Config -> [String] -> (Interpreter -> IO r) -> IO r
withInterpreter config args = bracket (new config args) close

sanitizeEnv :: [(String, String)] -> [(String, String)]
sanitizeEnv = filter p
  where
    p ("HSPEC_FAILURES", _) = False
    p _ = True

new :: Config -> [String] -> IO Interpreter
new Config{..} args_ = do

  requireFile configStartupFile
  startupFile <- makeAbsolute configStartupFile
  env <- sanitizeEnv <$> getEnvironment
  let
    args = "-ghci-script" : startupFile : args_ ++ catMaybes [
        if configIgnoreDotGhci then Just "-ignore-dot-ghci" else Nothing
      ]

  (Just stdin_, Just stdout_, Nothing, processHandle ) <- createProcess (proc "ghci" args) {
    cwd = configWorkingDirectory
  , env = Just env
  , std_in  = CreatePipe
  , std_out = CreatePipe
  , std_err = Inherit
  }

  setMode stdin_
  readHandle <- toReadHandle stdout_ 1024

  let
    interpreter = Interpreter {
      hIn = stdin_
    , readHandle
    , hOut = stdout_
    , process = processHandle
    , echo = configEcho
    }

  _ <- printStartupMessages interpreter

  evalThrow interpreter "GHC.IO.Handle.hDuplicateTo System.IO.stdout System.IO.stderr"

  -- GHCi uses NoBuffering for stdout and stderr by default:
  -- https://downloads.haskell.org/ghc/9.4.4/docs/users_guide/ghci.html
  evalThrow interpreter "GHC.IO.Handle.hSetBuffering System.IO.stdout GHC.IO.Handle.LineBuffering"
  evalThrow interpreter "GHC.IO.Handle.hSetBuffering System.IO.stderr GHC.IO.Handle.LineBuffering"

  evalThrow interpreter "GHC.IO.Handle.hSetEncoding System.IO.stdout GHC.IO.Encoding.utf8"
  evalThrow interpreter "GHC.IO.Handle.hSetEncoding System.IO.stderr GHC.IO.Encoding.utf8"

  return interpreter
  where
    requireFile name = do
      exists <- doesFileExist name
      unless exists $ do
        die $ "Required file " <> show name <> " does not exist!"

    setMode h = do
      hSetBinaryMode h False
      hSetBuffering h LineBuffering
      hSetEncoding h utf8

    printStartupMessages interpreter = evalVerbose interpreter ""

    evalThrow :: Interpreter -> String -> IO ()
    evalThrow interpreter expr = do
      output <- eval interpreter expr
      unless (null output) $ do
        close interpreter
        die output

close :: Interpreter -> IO ()
close Interpreter{..} = do
  hClose hIn
  ReadHandle.drain readHandle echo
  hClose hOut
  e <- waitForProcess process
  when (e /= ExitSuccess) $ do
    throwIO (userError $ "Language.Haskell.GhciWrapper.close: Interpreter exited with an error (" ++ show e ++ ")")

putExpression :: Interpreter -> String -> IO ()
putExpression Interpreter{hIn = stdin} e = do
  hPutStrLn stdin e
  B.hPut stdin ReadHandle.marker
  hFlush stdin

getResult :: Interpreter -> IO String
getResult Interpreter{..} = T.unpack . decodeUtf8 <$> ReadHandle.getResult readHandle echo

silent :: ByteString -> IO ()
silent _ = pass

eval :: Interpreter -> String -> IO String
eval ghci = evalVerbose ghci {echo = silent}

evalVerbose :: Interpreter -> String -> IO String
evalVerbose ghci expr = putExpression ghci expr >> getResult ghci
