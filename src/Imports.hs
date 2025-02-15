module Imports (module Imports) where

import           Control.Arrow as Imports ((>>>), (&&&))
import           Control.Concurrent as Imports
import           Control.Exception as Imports
import           Control.Monad as Imports
import           Data.Functor as Imports
import           Data.Bifunctor as Imports
import           Data.Char as Imports
import           Data.Either as Imports
import           Data.List as Imports
import           Data.Maybe as Imports
import           Data.String as Imports
import           Data.ByteString.Char8 as Imports (ByteString, pack, unpack)
import           Data.Tuple as Imports
import           System.FilePath as Imports hiding (combine)
import           System.IO.Error as Imports (isDoesNotExistError)
import           Text.Read as Imports (readMaybe)

pass :: Applicative m => m ()
pass = pure ()

while :: Monad m => m Bool -> m () -> m ()
while p action = go
  where
    go = do
      notDone <- p
      when notDone $ do
        action
        go
