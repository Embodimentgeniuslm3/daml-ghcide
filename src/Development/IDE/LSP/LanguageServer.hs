-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification  #-}

-- WARNING: A copy of DA.Daml.LanguageServer, try to keep them in sync
-- This version removes the daml: handling
module Development.IDE.LSP.LanguageServer
    ( runLanguageServer
    ) where

import qualified Language.LSP.Server as LSP
import           Language.LSP.Types
import           Development.IDE.LSP.Server
import qualified Development.IDE.GHC.Util as Ghcide
import Control.Concurrent.Chan
import Control.Concurrent.Extra
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception.Safe
import Data.Aeson (Value)
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Text as T
import GHC.IO.Handle (hDuplicate)
import System.IO
import Control.Monad.Extra
import Control.Monad.Reader

import Development.IDE.Core.FileStore
import Development.IDE.Core.IdeConfiguration
import Development.IDE.Core.Shake
import Development.IDE.LSP.HoverDefinition
import Development.IDE.LSP.Notifications
import Development.IDE.Plugin
import Development.IDE.Types.Logger

runLanguageServer
    :: forall config. (Show config)
    => LSP.Options
    -> config
    -> (config -> Value -> Either T.Text config)
    -> Plugin config
    -> (LSP.LanguageContextEnv config -> VFSHandle -> Maybe FilePath -> IO IdeState)
    -> IO ()
runLanguageServer options defaultConfig onConfigurationChange userHandlers getIdeState = do
    -- Move stdout to another file descriptor and duplicate stderr
    -- to stdout. This guards against stray prints from corrupting the JSON-RPC
    -- message stream.
    newStdout <- hDuplicate stdout
    stderr `Ghcide.hDuplicateTo'` stdout
    hSetBuffering stderr NoBuffering
    hSetBuffering stdout NoBuffering

    -- Print out a single space to assert that the above redirection works.
    -- This is interleaved with the logger, hence we just print a space here in
    -- order not to mess up the output too much. Verified that this breaks
    -- the language server tests without the redirection.
    putStr " " >> hFlush stdout

    -- These barriers are signaled when the threads reading from these chans exit.
    -- This should not happen but if it does, we will make sure that the whole server
    -- dies and can be restarted instead of losing threads silently.
    clientMsgBarrier <- newBarrier
    -- Forcefully exit
    let exit = signalBarrier clientMsgBarrier ()

    -- The set of requests ids that we have received but not finished processing
    pendingRequests <- newTVarIO Set.empty
    -- The set of requests that have been cancelled and are also in pendingRequests
    cancelledRequests <- newTVarIO Set.empty

    let cancelRequest reqId = atomically $ do
            queued <- readTVar pendingRequests
            -- We want to avoid that the list of cancelled requests
            -- keeps growing if we receive cancellations for requests
            -- that do not exist or have already been processed.
            when (reqId `elem` queued) $
                modifyTVar cancelledRequests (Set.insert reqId)
    let clearReqId reqId = atomically $ do
            modifyTVar pendingRequests (Set.delete reqId)
            modifyTVar cancelledRequests (Set.delete reqId)
        -- We implement request cancellation by racing waitForCancel against
        -- the actual request handler.
    let waitForCancel reqId = atomically $ do
            cancelled <- readTVar cancelledRequests
            unless (reqId `Set.member` cancelled) retry

    let ideHandlers = mconcat
            [ setIdeHandlers
            , allPluginHandlers (userHandlers <> setHandlersNotifications)
            ]

    -- Send everything over a channel, since you need to wait until after initialise before
    -- LspFuncs is available
    clientMsgChan :: Chan ReactorMessage <- newChan

    let asyncHandlers = mconcat
          [ ideHandlers
          , cancelHandler cancelRequest
          , exitHandler exit
          ]
          -- Cancel requests are special since they need to be handled
          -- out of order to be useful. Existing handlers are run afterwards.

    let serverDefinition = LSP.ServerDefinition
            { LSP.onConfigurationChange = onConfigurationChange
            , LSP.doInitialize = handleInit exit clearReqId waitForCancel clientMsgChan
            , LSP.staticHandlers = asyncHandlers
            , LSP.interpretHandler = \(env, st) -> LSP.Iso (LSP.runLspT env . flip runReaderT (clientMsgChan,st)) liftIO
            , LSP.options = modifyOptions options
            , LSP.defaultConfig = defaultConfig
            }

    void $ waitAnyCancel =<< traverse async
        [ void $ LSP.runServerWithHandles
            stdin
            newStdout
            serverDefinition
        , void $ waitBarrier clientMsgBarrier
        ]
    where
        handleInit
          :: IO () -> (SomeLspId -> IO ()) -> (SomeLspId -> IO ()) -> Chan ReactorMessage
          -> LSP.LanguageContextEnv config -> RequestMessage 'Initialize -> IO (Either err (LSP.LanguageContextEnv config, IdeState))
        handleInit exitClientMsg clearReqId waitForCancel clientMsgChan env (RequestMessage _ _ _ params) = do
            let root = LSP.resRootPath env
            ide <- liftIO $ getIdeState env (makeLSPVFSHandle env) root

            let initConfig = parseConfiguration params
            liftIO $ logInfo (ideLogger ide) $ T.pack $ "Registering ide configuration: " <> show initConfig
            liftIO $ registerIdeConfiguration (shakeExtras ide) initConfig

            _ <- flip forkFinally (const exitClientMsg) $ forever $ do
                msg <- readChan clientMsgChan
                case msg of
                    ReactorNotification act ->
                      catch act $ \(e :: SomeException) ->
                        logError (ideLogger ide) $ T.pack $
                          "Unexpected exception on notification, please report!\n" ++
                          "Exception: " ++ show e
                    ReactorRequest _id act k -> void $
                      checkCancelled ide clearReqId waitForCancel _id act k
            pure $ Right (env,ide)

        checkCancelled
          :: IdeState -> (SomeLspId -> IO ()) -> (SomeLspId -> IO ()) -> SomeLspId
          -> IO () -> (ResponseError -> IO ()) -> IO ()
        checkCancelled ide clearReqId waitForCancel _id act k =
            flip finally (liftIO $ clearReqId _id) $
                catchAsync (do
                    -- We could optimize this by first checking if the id
                    -- is in the cancelled set. However, this is unlikely to be a
                    -- bottleneck and the additional check might hide
                    -- issues with async exceptions that need to be fixed.
                    cancelOrRes <- race (liftIO $ waitForCancel _id) act
                    case cancelOrRes of
                        Left () -> do
                            logDebug (ideLogger ide) $ T.pack $
                                "Cancelled request " <> show _id
                            k $ ResponseError RequestCancelled "" Nothing
                        Right res -> pure res
                ) $ \(e :: SomeException) ->
                    -- A call to runAction can fail with AsyncCancelled if we mess up our concurrency management.
                    -- We want to catch that exception and print it here instead of silently dying.
                    -- We still shouldn’t catch UserInterrupt or other stuff so we rethrow every
                    -- other asynchronous exception.
                    if isSyncException e || isJust (fromException @AsyncCancelled e)
                      then do
                        liftIO $ logError (ideLogger ide) $ T.pack $
                            "Unexpected exception on request, please report!\n" ++
                            "Exception: " ++ show e
                        k $ ResponseError InternalError (T.pack $ show e) Nothing
                      else throwIO e

cancelHandler :: (SomeLspId -> IO ()) -> LSP.Handlers (ServerM c)
cancelHandler cancelRequest = LSP.notificationHandler SCancelRequest $ \NotificationMessage{_params=CancelParams{_id}} ->
  liftIO $ cancelRequest (SomeLspId _id)

exitHandler :: IO () -> LSP.Handlers (ServerM c)
exitHandler exit = LSP.notificationHandler SExit (const $ liftIO exit)

modifyOptions :: LSP.Options -> LSP.Options
modifyOptions x = x{ LSP.textDocumentSync   = Just $ tweakTDS origTDS
                   }
    where
        tweakTDS tds = tds{_openClose=Just True, _change=Just TdSyncIncremental, _save=Just $ InR $ SaveOptions Nothing}
        origTDS = fromMaybe tdsDefault $ LSP.textDocumentSync x
        tdsDefault = TextDocumentSyncOptions Nothing Nothing Nothing Nothing Nothing
