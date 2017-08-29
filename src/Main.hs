{-# LANGUAGE GADTs #-}

module Main
(
    main
)
where

import Graphics.QML (SignalKey, MarshalMode, IIsObjType, Yes, ICanPassTo, 
                     Marshal, newSignalKey, newClass, defPropertySigRO', 
                     defMethod', newObject, runEngineLoop, defaultEngineConfig,
                     fileDocument, anyObjRef, fireSignal, initialDocument, 
                     contextObject)

import Data.Text (Text, pack, unpack)

import Control.Concurrent (ThreadId, MVar, forkIO, killThread, newEmptyMVar,
                           tryTakeMVar, putMVar, isEmptyMVar, swapMVar,
                           threadDelay)

import Control.Exception (IOException, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.Directory (getPermissions, writable)
import Control.Monad (when, void, unless)
import Data.List (stripPrefix)

import Find (find)
import Messages (permissionError, noInternet, noImages)
import Utilities (addBaseAddress, noImagesExist, openURL, replaceSpace)
import Links (getImageLinks)
import Download (download)

import Paths_rule34_paheal_downloader (getDataFileName)

data StatesNSignals = StatesNSignals {
    searchSignal :: SignalKey (IO ()),
    mbTextSignal :: SignalKey (IO ()),
    mbVisibleSignal :: SignalKey (IO ()),
    mbButtonsSignal :: SignalKey (IO ()),
    uiEnabledSignal :: SignalKey (IO ()),
    searchState :: IORef [Text],
    mbTextState :: IORef Text,
    mbVisibleState :: IORef Bool,
    mbButtonsState :: IORef Text,
    uiEnabledState :: IORef Bool,
    threadMVar :: MVar ThreadId
}

main :: IO ()
main = do
    gui <- getDataFileName "src/main.qml"

    searchSig <- newSignalKey
    mbTextSig <- newSignalKey
    mbVisibleSig <- newSignalKey
    mbButtonsSig <- newSignalKey
    uiEnabledSig <- newSignalKey

    searchS <- newIORef $ map pack [""]
    mbTextS <- newIORef $ pack ""
    mbVisibleS <- newIORef False
    mbButtonsS <- newIORef $ pack "NoButton"
    uiEnabledS <- newIORef True

    thread <- newEmptyMVar

    let s = StatesNSignals searchSig mbTextSig mbVisibleSig mbButtonsSig uiEnabledSig
                           searchS mbTextS mbVisibleS mbButtonsS uiEnabledS thread
    
    rootClass <- newClass [
        defPropertySigRO' "searchResults" (searchSignal s) 
                        $ defRead (searchState s),

        defPropertySigRO' "msgText" (mbTextSignal s) 
                        $ defRead (mbTextState s),

        defPropertySigRO' "msgVisible" (mbVisibleSignal s) 
                        $ defRead (mbVisibleState s),

        defPropertySigRO' "msgButtons" (mbButtonsSignal s) 
                        $ defRead (mbButtonsState s),

        defPropertySigRO' "uiEnabled" (uiEnabledSignal s)
                        $ defRead (uiEnabledState s),

        defMethod' "search" (searchMethod s),

        defMethod' "download" (downloadMethod s),
        
        defMethod' "cancel" (cancelMethod s),
        
        defMethod' "markAsHidden" (markAsHiddenMethod s)]

    ctx <- newObject rootClass ()

    runEngineLoop defaultEngineConfig {
        initialDocument = fileDocument gui,
        contextObject = Just $ anyObjRef ctx
    }

    where defRead s _ = readIORef s

guiLogger :: (MarshalMode tt IIsObjType () ~ Yes, 
              MarshalMode tt ICanPassTo () ~ Yes, 
              Marshal tt) => StatesNSignals -> tt -> String -> IO ()
guiLogger s this msg = writeMsg s this msg "Cancel"

searchMethod :: (MarshalMode tt IIsObjType () ~ Yes, 
                 MarshalMode tt ICanPassTo () ~ Yes, 
                 Marshal tt) => StatesNSignals -> tt -> Text -> IO ()
searchMethod s this searchTerm = do
    disableUI s this

    writeMsg s this "Searching..." "Cancel"

    threadId <- forkIO $ do
        results <- find . map replaceSpace $ unpack searchTerm
        case results of
            Left err -> writeMsg s this err "Ok"
            Right results' -> do
                hideMsg s this

                writeIORef (searchState s) (map pack results')
                fireSignal (searchSignal s) this
        enableUI s this

    empty <- isEmptyMVar (threadMVar s)
    if empty
        then putMVar (threadMVar s) threadId
        else void $ swapMVar (threadMVar s) threadId

downloadMethod :: (MarshalMode tt ICanPassTo () ~ Yes, 
                   MarshalMode tt IIsObjType () ~ Yes, 
                   Marshal tt) => StatesNSignals -> tt -> 
                   Text -> Text -> IO ()
downloadMethod s this tag' folder' = do
    let tag = unpack tag'
        Just folder = fmap (++ "/") . stripPrefix "file://" $ unpack folder'

    permissions <- getPermissions folder

    if not $ writable permissions
        then writeMsg s this permissionError "Ok"
        else do
            threadId <- forkIO $ do
                disableUI s this

                writeMsg s this "Finding links..." "Cancel"
                let url = addBaseAddress tag
                firstpage <- try $ openURL url :: IO (Either IOException
                                                             String)
                case firstpage of
                    Left _ -> writeMsg s this noInternet "Ok"
                    Right val -> if noImagesExist val
                        then writeMsg s this noImages "Ok"
                        else do
                            imageLinks <- getImageLinks url (guiLogger s this)
                            download folder imageLinks (guiLogger s this)

                hideMsg s this
                enableUI s this

            empty <- isEmptyMVar (threadMVar s)
            if empty
                then putMVar (threadMVar s) threadId
                else void $ swapMVar (threadMVar s) threadId

writeMsg :: (MarshalMode tt IIsObjType () ~ Yes, 
             MarshalMode tt ICanPassTo () ~ Yes, 
             Marshal tt) => StatesNSignals -> tt -> String -> String -> IO ()
writeMsg s this msg buttonType = do
    hideMsg s this

    writeIORef (mbTextState s) (pack msg)
    writeIORef (mbButtonsState s) (pack buttonType)
    writeIORef (mbVisibleState s) True

    fireSignal (mbTextSignal s) this
    fireSignal (mbButtonsSignal s) this
    fireSignal (mbVisibleSignal s) this

hideMsg :: (MarshalMode tt IIsObjType () ~ Yes, 
            MarshalMode tt ICanPassTo () ~ Yes, 
            Marshal tt) => StatesNSignals -> tt -> IO ()
hideMsg s this = do
    windowEnabled <- readIORef (mbVisibleState s)
    when windowEnabled $ do
        writeIORef (mbVisibleState s) False
        fireSignal (mbVisibleSignal s) this
        --window doesn't reappear unless we threadDelay a bit
        threadDelay 1000

cancelMethod :: (MarshalMode tt ICanPassTo () ~ Yes, 
                 MarshalMode tt IIsObjType () ~ Yes, 
                 Marshal tt) => StatesNSignals -> tt -> IO ()
cancelMethod s this = do
    maybeMVar <- tryTakeMVar (threadMVar s)
    case maybeMVar of
        Nothing -> return ()
        Just thread -> do
            killThread thread
            hideMsg s this
    enableUI s this

disableUI :: (MarshalMode tt ICanPassTo () ~ Yes, 
              MarshalMode tt IIsObjType () ~ Yes, 
              Marshal tt) => StatesNSignals -> tt -> IO ()
disableUI s this = do
    uiEnabled <- readIORef (uiEnabledState s)
    when uiEnabled $ do
        writeIORef (uiEnabledState s) False
        fireSignal (uiEnabledSignal s) this

enableUI :: (MarshalMode tt ICanPassTo () ~ Yes, 
             MarshalMode tt IIsObjType () ~ Yes, 
             Marshal tt) => StatesNSignals -> tt -> IO ()
enableUI s this = do
    uiEnabled <- readIORef (uiEnabledState s)
    unless uiEnabled $ do
        writeIORef (uiEnabledState s) True
        fireSignal (uiEnabledSignal s) this

-- when the user clicks OK/Cancel, it hides the message, but doesn't update
-- the msgVisible property, hence windows don't do what is wanted after this
-- we just need to manually update it when a button is clicked
markAsHiddenMethod :: StatesNSignals -> t -> IO ()
markAsHiddenMethod s _ = writeIORef (mbVisibleState s) False
