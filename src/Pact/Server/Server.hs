{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}


-- |
-- Module      :  Pact.Server.Server
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Launch pact dev server.

module Pact.Server.Server
  ( serve
  ) where

import Control.Concurrent
import Control.Monad
import Control.Monad.State
import Control.Exception

import Data.Aeson
import qualified Data.Yaml as Y
import qualified Data.ByteString.Char8 as B8

import qualified Data.HashMap.Strict as HashMap

import Data.Monoid
import Data.Word (Word16)
import GHC.Generics
import System.Log.FastLogger

import Pact.Types.Command
import Pact.Types.Runtime hiding (Update,(<>))
import Pact.Types.SQLite
import Pact.Types.Server
import Pact.Server.ApiServer
import Pact.Server.History.Service
import Pact.Server.PactService

data Config = Config {
  _port :: Word16,
  _persistDir :: Maybe FilePath,
  _logDir :: FilePath,
  _pragmas :: [Pragma],
  _verbose :: Bool
  } deriving (Eq,Show,Generic)
instance ToJSON Config where toJSON = lensyToJSON 1
instance FromJSON Config where parseJSON = lensyParseJSON 1

usage :: String
usage =
  "Config file is YAML format with the following properties: \n\
  \port       - HTTP server port \n\
  \persistDir - Directory for database files. \n\
  \             If ommitted, runs in-memory only. \n\
  \logDir     - Directory for HTTP logs \n\
  \pragmas    - SQLite pragmas to use with persistence DBs \n\
  \\n"

serve :: FilePath -> IO ()
serve configFile = do
  Config {..} <- Y.decodeFileEither configFile >>=
                 either (\e -> throwIO (userError ("Error loading config: " ++ show e ++ "\n\n" ++ usage))) return
  (inC,histC) <- initChans
  replayFromDisk' <- ReplayFromDisk <$> newEmptyMVar
  debugFn <- if _verbose then initFastLogger else return (return . const ())
  let cmdConfig = CommandConfig (fmap (++ "/pact.sqlite") _persistDir) debugFn "entity" _pragmas
  let histConf = initHistoryEnv histC inC _persistDir debugFn replayFromDisk'
  _ <- forkIO $ startCmdThread cmdConfig inC histC replayFromDisk' debugFn
  _ <- forkIO $ runHistoryService histConf Nothing
  runApiServer histC inC debugFn (fromIntegral _port) _logDir

initFastLogger :: IO (String -> IO ())
initFastLogger = do
  tc <- newTimeCache "%Y/%m/%d-%H:%M:%S"
  (tfl,_) <- newTimedFastLogger tc (LogStdout 1000)
  return $ \m -> tfl $ \t -> toLogStr t <> " " <> toLogStr (B8.pack m) <> "\n"

startCmdThread :: CommandConfig -> InboundPactChan -> HistoryChannel -> ReplayFromDisk -> (String -> IO ()) -> IO ()
startCmdThread cmdConfig inChan histChan (ReplayFromDisk rp) debugFn = do
  CommandExecInterface {..} <- initPactService cmdConfig
  void $ (`runStateT` (0 :: TxId)) $ do
    -- we wait for the history service to light up, possibly giving us backups from disk to replay
    replayFromDisk' <- liftIO $ takeMVar rp
    if null replayFromDisk'
      then liftIO $ debugFn "[disk replay]: No replay found"
      else do
      forM_ replayFromDisk' $ \cmd -> do
        liftIO $ debugFn $ "[disk replay]: replaying => " ++ show cmd
        txid <- state (\i -> (i,succ i))
        liftIO $ _ceiApplyCmd (Transactional txid) cmd
      -- NB: we don't want to update history with the results from the replay
      forever $ do
        -- now we're prepared, so start taking new entries
        inb <- liftIO $ readInbound inChan
        case inb of
          TxCmds cmds -> do
            resps <- forM cmds $ \cmd -> do
              txid <- state (\i -> (i,succ i))
              liftIO $ _ceiApplyCmd (Transactional txid) cmd
            liftIO $ writeHistory histChan $ Update $ HashMap.fromList $ (\cmdr@CommandResult{..} -> (_crReqKey, cmdr)) <$> resps
          LocalCmd cmd mv -> do
            CommandResult {..} <- liftIO $ _ceiApplyCmd Local cmd
            liftIO $ putMVar mv _crResult