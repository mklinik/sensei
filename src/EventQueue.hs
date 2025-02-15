{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
module EventQueue (
  EventQueue
, newQueue

, Event(..)
, FileEventType(..)
, emitEvent

, Status(..)
, processQueue

#ifdef TEST
, Action(..)
, processEvents
, combineFileEvents
, groupFileEvents
#endif
) where

import           Imports

import           Control.Monad.STM
import           Control.Concurrent.STM.TChan

import           Util

type EventQueue = TChan Event

data Event = TriggerAll | FileEvent FileEventType FilePath | Done
  deriving (Eq, Show)

data FileEventType = FileAdded | FileRemoved | FileModified
  deriving (Eq, Show)

newQueue :: IO EventQueue
newQueue = atomically newTChan

emitEvent :: EventQueue -> Event -> IO ()
emitEvent chan = atomically . writeTChan chan

readEvents :: EventQueue -> IO [Event]
readEvents chan = do
  e <- atomically $ readTChan chan
  unless (isKeyboardInput e) $ do
    threadDelay 100000
  es <- atomically emptyQueue
  return (e : es)
  where
    isKeyboardInput :: Event -> Bool
    isKeyboardInput event = event == Done || event == TriggerAll

    emptyQueue :: STM [Event]
    emptyQueue = do
      mEvent <- tryReadTChan chan
      case mEvent of
        Nothing -> return []
        Just e -> (e :) <$> emptyQueue

data Status = Terminate | Reload

processQueue :: FilePath -> EventQueue -> IO () -> IO () -> IO Status
processQueue dir chan triggerAll trigger = go
  where
    go = readEvents chan >>= processEvents dir >>= \ case
      NoneAction -> do
        go
      TriggerAction files -> do
        output files
        trigger
        go
      TriggerAllAction -> do
        triggerAll
        go
      ReloadAction file t -> do
        output [file <> " (" <> show t <> ", reloading)"]
        return Reload
      DoneAction -> do
        return Terminate

    output :: [String] -> IO ()
    output = mapM_ (putStrLn . withInfoColor . mappend "--> ")

data Action = NoneAction | TriggerAction [FilePath] | TriggerAllAction | ReloadAction FilePath FileEventType | DoneAction
  deriving (Eq, Show)

processEvents :: FilePath -> [Event] -> IO Action
processEvents dir events = do
  files <- fileEvents dir events
  return $ if
    | Done `elem` events -> DoneAction
    | (file, t) : _ <- filter shouldReload files -> ReloadAction file t
    | TriggerAll `elem` events -> TriggerAllAction
    | not (null files) -> TriggerAction $ nub . sort $ map fst files
    | otherwise -> NoneAction

shouldReload :: (FilePath, FileEventType) -> Bool
shouldReload (name, event) = "Spec.hs" `isSuffixOf` name && case event of
  FileAdded -> True
  FileRemoved -> True
  FileModified -> False

fileEvents :: FilePath -> [Event] -> IO [(FilePath, FileEventType)]
fileEvents dir events = filterGitIgnored dir $ combineFileEvents [(p, e) | FileEvent e p <- events]

filterGitIgnored :: FilePath -> [(FilePath, FileEventType)] -> IO [(FilePath, FileEventType)]
filterGitIgnored dir events = map f <$> filterGitIgnoredFiles dir (map fst events)
  where
    f :: FilePath -> (FilePath, FileEventType)
    f p = (p, fromJust $ lookup p events)

combineFileEvents :: [(FilePath, FileEventType)] -> [(FilePath, FileEventType)]
combineFileEvents events = [(file, e) | (file, Just e) <- map (second combineFileEventTypes) $ groupFileEvents events]

groupFileEvents :: [(FilePath, FileEventType)] -> [(FilePath, [FileEventType])]
groupFileEvents = map (second $ map snd) . groupOn fst

groupOn :: Eq b => (a -> b) -> [a] -> [(b, [a])]
groupOn f = go
  where
    go = \ case
      [] -> []
      x : xs -> case partition (\ a -> f a == f x) xs of
        (ys, zs) -> (f x, (x : ys)) : go zs

combineFileEventTypes :: [FileEventType] -> Maybe FileEventType
combineFileEventTypes = go
  where
    go events = case events of
      [] -> Nothing
      [e] -> Just e
      e1 : e2 : es -> go $ (combine e1 e2) es

    combine e1 e2 = case (e1, e2) of
      (FileAdded, FileAdded) -> ignoreDuplicate FileAdded
      (FileAdded, FileRemoved) -> id
      (FileAdded, FileModified) -> (FileAdded :)

      (FileRemoved, FileAdded) -> (FileModified :)
      (FileRemoved, FileRemoved) -> ignoreDuplicate FileRemoved
      (FileRemoved, FileModified) -> shouldNeverHappen

      (FileModified, FileAdded) -> shouldNeverHappen
      (FileModified, FileRemoved) -> (FileRemoved :)
      (FileModified, FileModified) -> ignoreDuplicate FileModified

    ignoreDuplicate = (:)
    shouldNeverHappen = (FileModified :)
