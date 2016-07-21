{-# Options_GHC -Wno-unused-do-bind #-}

module Client.NetworkConnection
  ( NetworkConnection(..)
  , NetworkName
  , NetworkEvent(..)
  , createConnection
  , abortConnection
  , send
  ) where

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Concurrent.Async
import           Control.Exception
import           Control.Monad
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Data.Text
import           Data.Time
import           Network.Connection

import           Irc.RateLimit
import           Client.Connect
import           Client.ServerSettings

data NetworkConnection = NetworkConnection
  { connOutQueue :: !(Chan ByteString)
  , connThread   :: !(Async ())
  }

type NetworkName = Text

data NetworkEvent
  = NetworkLine  !NetworkName !ZonedTime !ByteString
  | NetworkError !NetworkName !ZonedTime !SomeException
  | NetworkClose !NetworkName !ZonedTime

instance Show NetworkConnection where
  showsPrec p _ = showParen (p > 10)
                $ showString "NetworkConnection _"

send :: NetworkConnection -> ByteString -> IO ()
send c = writeChan (connOutQueue c)

abortConnection :: NetworkConnection -> IO ()
abortConnection c =
  do let a = connThread c
     cancel a
     waitCatch a
     return ()

createConnection ::
  NetworkName ->
  ConnectionContext ->
  ServerSettings ->
  TChan NetworkEvent ->
  IO NetworkConnection
createConnection network cxt settings inQueue =
   do outQueue <- newChan

      supervisor <- async $
        do startConnection network cxt settings inQueue outQueue
             `catch` recordFailure
           recordNormalExit

      return NetworkConnection
        { connOutQueue = outQueue
        , connThread   = supervisor
        }
  where
    recordFailure :: SomeException -> IO ()
    recordFailure ex =
      case fromException ex of
        -- if this thread is aborted its connection is going
        -- to be forcibly removed from the connection state
        -- by the abort code and another network might start
        -- using this networkname, so no further messages
        -- should be added to the channel.
        Just ThreadKilled -> throwIO ex
        _ -> do now <- getZonedTime
                atomically (writeTChan inQueue (NetworkError network now ex))

    recordNormalExit :: IO ()
    recordNormalExit =
      do now <- getZonedTime
         atomically (writeTChan inQueue (NetworkClose network now))


startConnection ::
  NetworkName ->
  ConnectionContext ->
  ServerSettings ->
  TChan NetworkEvent ->
  Chan ByteString ->
  IO ()
startConnection network cxt settings onInput outQueue =
  do rate <- newRateLimitDefault
     withConnection cxt settings $ \h ->
       withAsync (sendLoop h outQueue rate)      $ \sender ->
       withAsync (receiveLoop network h onInput) $ \receiver ->
         do res <- waitEitherCatch sender receiver
            case res of
              Left  Right{}  -> fail "PANIC: sendLoop returned"
              Right Right{}  -> return ()
              Left  (Left e) -> throwIO e
              Right (Left e) -> throwIO e

sendLoop :: Connection -> Chan ByteString -> RateLimit -> IO ()
sendLoop h outQueue rate =
  forever $
    do msg <- readChan outQueue
       tickRateLimit rate
       connectionPut h msg

ircMaxMessageLength :: Int
ircMaxMessageLength = 512

receiveLoop :: NetworkName -> Connection -> TChan NetworkEvent -> IO ()
receiveLoop network h inQueue =
  do msg <- connectionGetLine ircMaxMessageLength h
     unless (B.null msg) $
       do now <- getZonedTime
          atomically (writeTChan inQueue (NetworkLine network now (B.init msg)))
          receiveLoop network h inQueue
