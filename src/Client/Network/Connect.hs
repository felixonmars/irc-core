{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Client.Network.Connect
Description : Interface to the connection package
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

This module is responsible for creating 'Connection' values
for a particular server as specified by a 'ServerSettings'.
This involves setting up certificate stores an mapping
network settings from the client configuration into the
network connection library.
-}

module Client.Network.Connect
  ( withConnection
  , ircPort
  , tlsParams
  ) where

import           Client.Configuration.ServerSettings
import           Control.Applicative
import           Control.Exception  (bracket)
import           Control.Lens
import qualified Data.Text.Encoding as Text
import           Network.Socket (PortNumber)
import           Hookup

tlsParams :: ServerSettings -> TlsParams
tlsParams ss = TlsParams
  { tpClientCertificate  = view ssTlsClientCert ss
  , tpClientPrivateKey   = view ssTlsClientKey ss <|> view ssTlsClientCert ss
  , tpServerCertificate  = view ssTlsServerCert ss
  , tpCipherSuite        = view ssTlsCiphers ss
  , tpCipherSuiteTls13   = view ssTls13Ciphers ss
  , tpVerify = view ssTlsVerify ss
  , tpClientPrivateKeyPassword =
      case view ssTlsClientKeyPassword ss of
        Just (SecretText str) -> Just (Text.encodeUtf8 str)
        _                     -> Nothing
  }

proxyParams :: ServerSettings -> Maybe SocksParams
proxyParams ss =
  view ssSocksHost ss <&> \host ->
  SocksParams host (view ssSocksPort ss)

buildConnectionParams :: ServerSettings -> ConnectionParams
buildConnectionParams ss = ConnectionParams
  { cpHost  = view ssHostName ss
  , cpPort  = ircPort ss
  , cpTls   = case view ssTls ss of
                TlsYes   -> Just (tlsParams ss)
                TlsNo    -> Nothing
                TlsStart -> Nothing
  , cpSocks = proxyParams ss
  , cpBind  = view ssBindHostName ss
  }

ircPort :: ServerSettings -> PortNumber
ircPort args =
  case view ssPort args of
    Just p -> fromIntegral p
    Nothing ->
      case view ssTls args of
        TlsYes   -> 6697
        TlsNo    -> 6667
        TlsStart -> 6667

-- | Create a new 'Connection' which will be closed when the continuation
-- finishes.
withConnection :: ServerSettings -> (Connection -> IO a) -> IO a
withConnection settings k =
  bracket (connect (buildConnectionParams settings)) close k
