{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}

module Amazon
    ( liveConf

    , AmazonT (..)
    , runAmazonT

    , amazonRequest
    , amazonGet

    , module Amazon.Types
    ) where

import           Amazon.Types
import           Control.Applicative
import           Control.Monad.Base
import           Control.Monad.Error
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import qualified Data.ByteString              as BS
import qualified Data.ByteString.Base64       as Base64
import qualified Data.ByteString.Char8        as Char8
import qualified Data.ByteString.Lazy         as LBS
import           Data.Conduit
import           Data.Digest.Pure.SHA
import           Data.Function
import           Data.List
import           Data.String
import           Data.Text                    as T
import           Data.Text.Encoding           as TE
import           Data.Time
import           Data.XML.Pickle
import           Data.XML.Types
import           Network.HTTP.Conduit
import           Network.HTTP.Types.URI
import           System.Locale
import           Text.XML.Unresolved

version :: Text
version = "2011-08-01"

liveConf :: Manager -> AccessID -> AccessSecret -> AssociateTag -> AmazonConf
liveConf = AmazonConf $ AmazonEndpoint
                        { endpointURL  = "https://webservices.amazon.com/onca/xml"
                        , endpointHost = "webservices.amazon.com"
                        , endpointPath = "/onca/xml"
                        }

newtype AmazonT a = AmazonT
        { unAmazonT :: ResourceT (ReaderT AmazonConf (ErrorT AmazonFailure IO)) a
        } deriving ( Functor, Applicative, Monad, MonadIO, MonadThrow
                   , MonadError AmazonFailure
                   , MonadReader AmazonConf
                   , MonadBase IO
                   , MonadResource )

runAmazonT :: AmazonConf -> AmazonT a -> IO (Either AmazonFailure a)
runAmazonT conf = runErrorT . flip runReaderT conf . runResourceT . unAmazonT

amazonRequest :: (MonadIO m, MonadThrow m, MonadReader AmazonConf m) =>
                    Text -> [(Text, Text)] -> m Request
amazonRequest opName opParams = do
        now <- liftIO $ getCurrentTime
        (AmazonConf{..}) <- ask
        let defParams = [ ("AssociateTag", amazonAssociateTag)
                        , ("AWSAccessKeyId", amazonAccessId)
                        , ("Operation", opName)
                        , ("Version", version)
                        , ("Timestamp", T.pack $ formatTime defaultTimeLocale timeFormat now)
                        ]
            fnParams  = sortBy (compare `on` fst) $ defParams ++ opParams
            paramsTxt = T.intercalate "&" $ fmap (\(k, v) -> T.concat [k, "=", v]) fnParams
            signTxt   = T.intercalate "\n" [ "GET"
                                           , endpointHost amazonEndpoint
                                           , endpointPath amazonEndpoint
                                           , paramsTxt
                                           ]
            paramsUrl = urlEncode True $ TE.encodeUtf8 paramsTxt
            signature = Base64.encode $ LBS.toStrict $ bytestringDigest $
                            hmacSha256 amazonAccessSecret $
                                LBS.fromStrict $ urlEncode True $ TE.encodeUtf8 signTxt
        parseUrl $ (endpointURL amazonEndpoint) ++ "?" ++ (Char8.unpack paramsUrl) ++
                    "&Signature=" ++ (Char8.unpack signature)

amazonGet :: Text -> [(Text, Text)] -> PU [Node] a -> AmazonT (OperationRequest, a)
amazonGet opName opParams resPickler = do
        (AmazonConf{..}) <- ask
        initReq <- amazonRequest opName opParams
        res <- http initReq amazonManager
        case responseStatus res of
            ok200 -> do doc@(Document _ root _) <- responseBody res $$+- sinkDoc def
                        let out = unpickle resXp (NodeElement root)
                        case out of
                            Left  e -> throwError $ ParseFailure $ Just e
                            Right s -> return s
    where resName = fromString $ T.unpack $
                        T.concat ["{http://ecs.amazonaws.com/doc/2011-08-01/}"
                                 , opName
                                 , "Response"
                                 ]
          resXp   = xpRoot $ xpElemNodes resName $ xpPair xpOperationRequest resPickler
