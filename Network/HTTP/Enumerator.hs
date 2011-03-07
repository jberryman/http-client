{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
-- | This module contains everything you need to initiate HTTP connections.  If
-- you want a simple interface based on URLs, you can use 'simpleHttp'. If you
-- want raw power, 'http' is the underlying workhorse of this package. Some
-- examples:
--
-- > -- Just download an HTML document and print it.
-- > import Network.HTTP.Enumerator
-- > import qualified Data.ByteString.Lazy as L
-- >
-- > main = simpleHttp "http://www.haskell.org/" >>= L.putStr
--
-- This example uses interleaved IO to write the response body to a file in
-- constant memory space. By using 'httpRedirect', it will automatically
-- follow 3xx redirects.
--
-- > import Data.Enumerator
-- > import Data.Enumerator.Binary
-- > import Network.HTTP.Enumerator
-- > import System.IO
-- > 
-- > main :: IO ()
-- > main = withFile "google.html" WriteMode $ \handle -> do
-- >     request <- parseUrl "http://google.com/"
-- >     run_ $ httpRedirect request (\_ _ -> iterHandle handle)
--
-- The following headers are automatically set by this module, and should not
-- be added to 'requestHeaders':
--
-- * Content-Length
--
-- * Host
--
-- * Accept-Encoding (not currently set, but client usage of this variable /will/ cause breakage).
--
-- Any network code on Windows requires some initialization, and the network
-- library provides withSocketsDo to perform it. Therefore, proper usage of
-- this library will always involve calling that function at some point.  The
-- best approach is to simply call them at the beginning of your main function,
-- such as:
--
-- > import Network.HTTP.Enumerator
-- > import qualified Data.ByteString.Lazy as L
-- > import Network (withSocketsDo)
-- >
-- > main = withSocketsDo
-- >      $ simpleHttp "http://www.haskell.org/" >>= L.putStr
module Network.HTTP.Enumerator
    ( -- * Perform a request
      simpleHttp
    , httpLbs
    , httpLbsRedirect
    , http
    , httpRedirect
    , redirectIter
      -- * Datatypes
    , Request (..)
    , Response (..)
    , Headers
      -- * Manager
    , Manager
    , newManager
    , closeManager
    , withManager
      -- * Utility functions
    , parseUrl
    , lbsIter
      -- * Request bodies
    , urlEncodedBody
      -- * Exceptions
    , HttpException (..)
    ) where

import System.IO (hClose)
import qualified Network.TLS.Client.Enumerator as TLS
import Network (connectTo, PortID (PortNumber))

import qualified Network.Socket as NS
import qualified Network.Socket.ByteString as B
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as S8
import Data.Enumerator
    ( Iteratee (..), Stream (..), catchError, throwError
    , yield, Step (..), Enumeratee, ($$), joinI, Enumerator, run_
    , continue, returnI, (>==>)
    )
import qualified Data.Enumerator.List as EL
import Network.HTTP.Enumerator.HttpParser
import Control.Exception (Exception, bracket)
import Control.Arrow (first)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Class (lift)
import Control.Failure
import Data.Typeable (Typeable)
import Data.Data (Data)
import Data.Word (Word8)
import Data.Bits
import Data.Maybe (fromMaybe)
import Data.ByteString.Lazy.Internal (defaultChunkSize)
import Codec.Binary.UTF8.String (encodeString)
import qualified Blaze.ByteString.Builder as Blaze
import Blaze.ByteString.Builder.Enumerator (builderToByteString)
import Data.Monoid (Monoid (..))
import qualified Network.Wai as W
import Data.Int (Int64)
import qualified Codec.Zlib
import qualified Codec.Zlib.Enum as Z
import Control.Monad.IO.Control (MonadControlIO, liftIOOp)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.IORef as I
import Control.Applicative ((<$>))

getSocket :: String -> Int -> IO NS.Socket
getSocket host' port' = do
    let hints = NS.defaultHints {
                          NS.addrFlags = [NS.AI_ADDRCONFIG]
                        , NS.addrSocketType = NS.Stream
                        }
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host') (Just $ show port')
    sock <- NS.socket (NS.addrFamily addr) (NS.addrSocketType addr)
                      (NS.addrProtocol addr)
    NS.connect sock (NS.addrAddress addr)
    return sock

withSocketConn :: MonadIO m
               => Manager
               -> String
               -> Int
               -> Enumerator Blaze.Builder m ()
               -> Enumerator S.ByteString m a
withSocketConn m host' port' req step0 = do
    sock <- liftIO $ takeInsecureSocket m host' port'
            >>= maybe (getSocket host' port') return
    lift $ run_ $ req $$ joinI $ builderToByteString $$ writeToIter $ B.sendAll sock
    a <- readToEnum (B.recv sock defaultChunkSize) step0
    liftIO $ putInsecureSocket m host' port' sock
    return a


writeToIter :: MonadIO m
            => (S.ByteString -> IO b) -> Iteratee S.ByteString m ()
writeToIter write =
    continue go
  where
    go EOF = return ()
    go (Chunks bss) = do
        liftIO $ mapM_ write bss
        continue go

readToEnum :: MonadIO m => IO S.ByteString -> Enumerator S.ByteString m b
readToEnum read' (Continue k) = do
    bs <- liftIO read'
    if S.null bs
        then continue k
        else do
            step <- lift $ runIteratee $ k $ Chunks [bs]
            readToEnum read' step
readToEnum _ step = returnI step

withSslConn :: MonadIO m
            => String -- ^ host
            -> Int -- ^ port
            -> Enumerator Blaze.Builder m () -- ^ request
            -> Enumerator S.ByteString m a -- ^ response
withSslConn host' port' req step0 = do
    handle <- liftIO $ connectTo host' (PortNumber $ fromIntegral port')
    a <- TLS.clientEnumSimple handle req step0
    liftIO $ hClose handle
    return a

-- | All information on how to connect to a host and what should be sent in the
-- HTTP request.
--
-- If you simply wish to download from a URL, see 'parseUrl'.
data Request m = Request
    { method :: S.ByteString -- ^ HTTP request method, eg GET, POST.
    , secure :: Bool -- ^ Whether to use HTTPS (ie, SSL).
    , host :: S.ByteString
    , port :: Int
    , path :: S.ByteString -- ^ Everything from the host to the query string.
    , queryString :: [(S.ByteString, S.ByteString)] -- ^ Automatically escaped for your convenience.
    , requestHeaders :: Headers
    , requestBody :: RequestBody m
    }

-- | When using the 'RequestBodyEnum' constructor and any function which calls
-- 'redirectIter', you must ensure that the 'Enumerator' can be called multiple
-- times.
data RequestBody m
    = RequestBodyLBS L.ByteString
    | RequestBodyEnum Int64 (Enumerator Blaze.Builder m ())

-- | A simple representation of the HTTP response created by 'lbsIter'.
data Response = Response
    { statusCode :: Int
    , responseHeaders :: Headers
    , responseBody :: L.ByteString
    }
    deriving (Show, Read, Eq, Typeable, Data)

type Headers = [(W.ResponseHeader, S.ByteString)]

enumSingle :: Monad m => a -> Enumerator a m b
enumSingle x (Continue k) = k $ Chunks [x]
enumSingle _ step = returnI step

-- | The most low-level function for initiating an HTTP request.
--
-- The second argument to this function gives a full specification on the
-- request: the host to connect to, whether to use SSL, headers, etc. Please
-- see 'Request' for full details.
--
-- The first argument specifies how the response should be handled. It's a
-- function that takes two arguments: the first is the HTTP status code of the
-- response, and the second is a list of all response headers. This module
-- exports 'lbsIter', which generates a 'Response' value.
--
-- Note that this allows you to have fully interleaved IO actions during your
-- HTTP download, making it possible to download very large responses in
-- constant memory.
http
     :: MonadIO m
     => Request m
     -> (W.Status -> W.ResponseHeaders -> Iteratee S.ByteString m a)
     -> Manager
     -> Iteratee S.ByteString m a
http Request {..} bodyStep m = do
    let h' = S8.unpack host
    let withConn = if secure then withSslConn else withSocketConn m
    withConn h' port requestEnum $$ go
  where
    (contentLength, bodyEnum) =
        case requestBody of
            RequestBodyLBS lbs -> (L.length lbs, enumSingle $ Blaze.fromLazyByteString lbs)
            RequestBodyEnum i enum -> (i, enum)
    hh
        | port == 80 && not secure = host
        | port == 443 && secure = host
        | otherwise = host `S.append` S8.pack (':' : show port)
    headers' = ("Host", hh)
                 : ("Content-Length", S8.pack $ show contentLength)
                 : ("Accept-Encoding", "gzip")
                 : requestHeaders
    requestHeaders' = mconcat
            [ Blaze.fromByteString method
            , Blaze.fromByteString " "
            , Blaze.fromByteString $
                case S8.uncons path of
                    Just ('/', _) -> path
                    _ -> S8.cons '/' path
            , renderQS queryString
            , Blaze.fromByteString " HTTP/1.1\r\n"
            , mconcat $ flip map headers' $ \(k, v) -> mconcat
                [ Blaze.fromByteString $ W.ciOriginal k
                , Blaze.fromByteString ": "
                , Blaze.fromByteString v
                , Blaze.fromByteString "\r\n"
                ]
            , Blaze.fromByteString "\r\n"
            ]
    requestEnum = enumSingle requestHeaders' >==> bodyEnum
    go = do
        ((_, sc, sm), hs) <- iterHeaders
        let s = W.Status sc sm
        let hs' = map (first W.mkCIByteString) hs
        let mcl = lookup "content-length" hs'
        let body' x =
                if ("transfer-encoding", "chunked") `elem` hs'
                    then joinI $ chunkedEnumeratee $$ x
                    else case mcl >>= readMay . S8.unpack of
                        Just len -> joinI $ takeLBS len $$ x
                        Nothing -> x
        let decompress x =
                if ("content-encoding", "gzip") `elem` hs'
                    then joinI $ Z.decompress (Codec.Zlib.WindowBits 31) x
                    else returnI x
        if method == "HEAD"
            then bodyStep s hs'
            else body' $ decompress $$ bodyStep s hs'

chunkedEnumeratee :: MonadIO m => Enumeratee S.ByteString S.ByteString m a
chunkedEnumeratee k@(Continue _) = do
    len <- catchParser "Chunk header" iterChunkHeader
    if len == 0
        then return k
        else do
            k' <- takeLBS len k
            catchParser "End of chunk newline" iterNewline
            chunkedEnumeratee k'
chunkedEnumeratee step = return step

takeLBS :: MonadIO m => Int -> Enumeratee S.ByteString S.ByteString m a
takeLBS 0 step = return step
takeLBS len (Continue k) = do
    mbs <- EL.head
    case mbs of
        Nothing -> return $ Continue k
        Just bs -> do
            let (len', chunk, rest) =
                    if S.length bs > len
                        then (0, S.take len bs,
                                if S.length bs == len
                                    then Chunks []
                                    else Chunks [S.drop len bs])
                        else (len - S.length bs, bs, Chunks [])
            step' <- lift $ runIteratee $ k $ Chunks [chunk]
            if len' == 0
                then yield step' rest
                else takeLBS len' step'
takeLBS _ step = return step

renderQS :: [(S.ByteString, S.ByteString)] -> Blaze.Builder
renderQS [] = mempty
renderQS (p:ps) = mconcat
    $ go "?" p
    : map (go "&") ps
  where
    go sep (k, v) =
        Blaze.copyByteString sep
        `mappend` Blaze.copyByteString (escape k)
        `mappend`
            (if S.null v
                then mempty
                else
                    Blaze.copyByteString "="
                    `mappend` Blaze.copyByteString (escape v))
    escape = S8.concatMap (S8.pack . encodeUrlChar)

encodeUrlCharPI :: Char -> String
encodeUrlCharPI '/' = "/"
encodeUrlCharPI c = encodeUrlChar c

encodeUrlChar :: Char -> String
encodeUrlChar c
    -- List of unreserved characters per RFC 3986
    -- Gleaned from http://en.wikipedia.org/wiki/Percent-encoding
    | 'A' <= c && c <= 'Z' = [c]
    | 'a' <= c && c <= 'z' = [c]
    | '0' <= c && c <= '9' = [c]
encodeUrlChar c@'-' = [c]
encodeUrlChar c@'_' = [c]
encodeUrlChar c@'.' = [c]
encodeUrlChar c@'~' = [c]
encodeUrlChar ' ' = "+"
encodeUrlChar y =
    let (a, c) = fromEnum y `divMod` 16
        b = a `mod` 16
        showHex' x
            | x < 10 = toEnum $ x + (fromEnum '0')
            | x < 16 = toEnum $ x - 10 + (fromEnum 'A')
            | otherwise = error $ "Invalid argument to showHex: " ++ show x
     in ['%', showHex' b, showHex' c]

-- | Convert a URL into a 'Request'.
--
-- This defaults some of the values in 'Request', such as setting 'method' to
-- GET and 'requestHeaders' to @[]@.
--
-- Since this function uses 'Failure', the return monad can be anything that is
-- an instance of 'Failure', such as 'IO' or 'Maybe'.
parseUrl :: Failure HttpException m => String -> m (Request m')
parseUrl s@('h':'t':'t':'p':':':'/':'/':rest) = parseUrl1 s False rest
parseUrl s@('h':'t':'t':'p':'s':':':'/':'/':rest) = parseUrl1 s True rest
parseUrl x = failure $ InvalidUrlException x "Invalid scheme"

parseUrl1 :: Failure HttpException m
          => String -> Bool -> String -> m (Request m')
parseUrl1 full sec s =
    parseUrl2 full sec s'
  where
    s' = encodeString s

parseUrl2 :: Failure HttpException m
          => String -> Bool -> String -> m (Request m')
parseUrl2 full sec s = do
    port' <- mport
    return Request
        { host = S8.pack hostname
        , port = port'
        , secure = sec
        , requestHeaders = []
        , path = S8.pack $ if null path'
                            then "/"
                            else concatMap encodeUrlCharPI path'
        , queryString = parseQueryString $ S8.pack qstring
        , requestBody = RequestBodyLBS L.empty
        , method = "GET"
        }
  where
    (beforeSlash, afterSlash) = break (== '/') s
    (hostname, portStr) = break (== ':') beforeSlash
    (path', qstring') = break (== '?') afterSlash
    qstring'' = case qstring' of
                '?':x -> x
                _ -> qstring'
    qstring = takeWhile (/= '#') qstring''
    mport =
        case (portStr, sec) of
            ("", False) -> return 80
            ("", True) -> return 443
            (':':rest, _) ->
                case readMay rest of
                    Just i -> return i
                    Nothing -> failure $ InvalidUrlException full "Invalid port"
            x -> error $ "parseUrl1: this should never happen: " ++ show x

parseQueryString :: S.ByteString -> [(S.ByteString, S.ByteString)]
parseQueryString = parseQueryString' . dropQuestion
  where
    dropQuestion q | S.null q || S.head q /= 63 = q
    dropQuestion q | otherwise = S.tail q
    parseQueryString' q | S.null q = []
    parseQueryString' q =
        let (x, xs) = breakDiscard 38 q -- ampersand
         in parsePair x : parseQueryString' xs
      where
        parsePair x =
            let (k, v) = breakDiscard 61 x -- equal sign
             in (qsDecode k, qsDecode v)


qsDecode :: S.ByteString -> S.ByteString
qsDecode z = fst $ S.unfoldrN (S.length z) go z
  where
    go bs =
        case uncons bs of
            Nothing -> Nothing
            Just (43, ws) -> Just (32, ws) -- plus to space
            Just (37, ws) -> Just $ fromMaybe (37, ws) $ do -- percent
                (x, xs) <- uncons ws
                x' <- hexVal x
                (y, ys) <- uncons xs
                y' <- hexVal y
                Just $ (combine x' y', ys)
            Just (w, ws) -> Just (w, ws)
    hexVal w
        | 48 <= w && w <= 57  = Just $ w - 48 -- 0 - 9
        | 65 <= w && w <= 70  = Just $ w - 55 -- A - F
        | 97 <= w && w <= 102 = Just $ w - 87 -- a - f
        | otherwise = Nothing
    combine :: Word8 -> Word8 -> Word8
    combine a b = shiftL a 4 .|. b

uncons :: S.ByteString -> Maybe (Word8, S.ByteString)
uncons s
    | S.null s = Nothing
    | otherwise = Just (S.head s, S.tail s)

breakDiscard :: Word8 -> S.ByteString -> (S.ByteString, S.ByteString)
breakDiscard w s =
    let (x, y) = S.break (== w) s
     in (x, S.drop 1 y)

-- | Convert the HTTP response into a 'Response' value.
--
-- Even though a 'Response' contains a lazy bytestring, this function does
-- /not/ utilize lazy I/O, and therefore the entire response body will live in
-- memory. If you want constant memory usage, you'll need to write your own
-- iteratee and use 'http' or 'httpRedirect' directly.
lbsIter :: Monad m => W.Status -> W.ResponseHeaders
        -> Iteratee S.ByteString m Response
lbsIter (W.Status sc _) hs = do
    lbs <- fmap L.fromChunks EL.consume
    return $ Response sc hs lbs

-- | Download the specified 'Request', returning the results as a 'Response'.
--
-- This is a simplified version of 'http' for the common case where you simply
-- want the response data as a simple datatype. If you want more power, such as
-- interleaved actions on the response body during download, you'll need to use
-- 'http' directly. This function is defined as:
--
-- @httpLbs = http lbsIter@
--
-- Please see 'lbsIter' for more information on how the 'Response' value is
-- created.
httpLbs :: MonadIO m => Request m -> Manager -> m Response
httpLbs req = run_ . http req lbsIter

-- | Download the specified URL, following any redirects, and return the
-- response body.
--
-- This function will 'failure' an 'HttpException' for any response with a
-- non-2xx status code. It uses 'parseUrl' to parse the input. This function
-- essentially wraps 'httpLbsRedirect'.
simpleHttp :: (MonadControlIO m, Failure HttpException m) => String -> m L.ByteString
simpleHttp url = do
    url' <- parseUrl url
    Response sc _ b <- withManager $ httpLbsRedirect url'
    if 200 <= sc && sc < 300
        then return b
        else failure $ StatusCodeException sc b

data HttpException = StatusCodeException Int L.ByteString
                   | InvalidUrlException String String
                   | TooManyRedirects
                   | HttpParserException String
    deriving (Show, Typeable)
instance Exception HttpException

-- | Same as 'http', but follows all 3xx redirect status codes that contain a
-- location header.
httpRedirect
    :: (MonadIO m, Failure HttpException m)
    => Request m
    -> (W.Status -> W.ResponseHeaders -> Iteratee S.ByteString m a)
    -> Manager
    -> Iteratee S.ByteString m a
httpRedirect req bodyStep manager =
    http req (redirectIter 10 req bodyStep manager) manager

-- | Make a request automatically follow 3xx redirects.
--
-- Used internally by 'httpRedirect' and family.
redirectIter :: (MonadIO m, Failure HttpException m)
             => Int -- ^ number of redirects to attempt
             -> Request m -- ^ Original request
             -> (W.Status -> W.ResponseHeaders -> Iteratee S.ByteString m a)
             -> Manager
             -> (W.Status -> W.ResponseHeaders -> Iteratee S.ByteString m a)
redirectIter redirects req bodyStep manager s@(W.Status code _) hs
    | 300 <= code && code < 400 =
        case lookup "location" hs of
            Just l'' -> do
                -- Prepend scheme, host and port if missing
                let l' =
                        case S8.uncons l'' of
                            Just ('/', _) -> concat
                                [ "http"
                                , if secure req then "s" else ""
                                , "://"
                                , S8.unpack $ host req
                                , ":"
                                , show $ port req
                                , S8.unpack l''
                                ]
                            _ -> S8.unpack l''
                l <- lift $ parseUrl l'
                let req' = req
                        { host = host l
                        , port = port l
                        , secure = secure l
                        , path = path l
                        , queryString = queryString l
                        , method =
                            if code == 303
                                then "GET"
                                else method l
                        }
                if redirects == 0
                    then lift $ failure TooManyRedirects
                    else (http req') (redirectIter (redirects - 1) req' bodyStep manager) manager
            Nothing -> bodyStep s hs
    | otherwise = bodyStep s hs

-- | Download the specified 'Request', returning the results as a 'Response'
-- and automatically handling redirects.
--
-- This is a simplified version of 'httpRedirect' for the common case where you
-- simply want the response data as a simple datatype. If you want more power,
-- such as interleaved actions on the response body during download, you'll
-- need to use 'httpRedirect' directly. This function is defined as:
--
-- @httpLbsRedirect = httpRedirect lbsIter@
--
-- Please see 'lbsIter' for more information on how the 'Response' value is
-- created.
httpLbsRedirect :: (MonadIO m, Failure HttpException m) => Request m -> Manager -> m Response
httpLbsRedirect req = run_ . httpRedirect req lbsIter

readMay :: Read a => String -> Maybe a
readMay s = case reads s of
                [] -> Nothing
                (x, _):_ -> Just x

-- FIXME add a helper for generating POST bodies

-- | Add url-encoded paramters to the 'Request'.
--
-- This sets a new 'requestBody', adds a content-type request header and
-- changes the 'method' to POST.
urlEncodedBody :: Monad m => [(S.ByteString, S.ByteString)] -> Request m' -> Request m
urlEncodedBody headers req = req
    { requestBody = RequestBodyLBS body
    , method = "POST"
    , requestHeaders =
        (ct, "application/x-www-form-urlencoded")
      : filter (\(x, _) -> x /= ct) (requestHeaders req)
    }
  where
    ct = "Content-Type"
    body = Blaze.toLazyByteString $ body' headers
    body' [] = mempty
    body' [x] = pair x
    body' (x:xs) = pair x `mappend` Blaze.fromWord8 38 `mappend` body' xs
    pair (x, y)
        | S.null y = single x
        | otherwise =
            single x `mappend` Blaze.fromWord8 61 `mappend` single y
    single = Blaze.fromWriteList go . S.unpack
    go 32 = Blaze.writeWord8 43 -- space to plus
    go c | unreserved c = Blaze.writeWord8 c
    go c =
        let x = shiftR c 4
            y = c .&. 15
         in Blaze.writeWord8 37 `mappend` hexChar x `mappend` hexChar y
    unreserved  45 = True -- hyphen
    unreserved  46 = True -- period
    unreserved  95 = True -- underscore
    unreserved 126 = True -- tilde
    unreserved c
        | 48 <= c && c <= 57  = True -- 0 - 9
        | 65 <= c && c <= 90  = True -- A - Z
        | 97 <= c && c <= 122 = True -- A - Z
    unreserved _ = False
    hexChar c
        | c < 10 = Blaze.writeWord8 $ c + 48
        | c < 16 = Blaze.writeWord8 $ c + 55
        | otherwise = error $ "hexChar: " ++ show c

catchParser :: Monad m => String -> Iteratee a m b -> Iteratee a m b
catchParser s i = catchError i (const $ throwError $ HttpParserException s)

-- | Keeps track of open connections for keep-alive.
data Manager = Manager
    { mInsecure :: I.IORef (Map (String, Int) NS.Socket)
    }

takeInsecureSocket :: Manager -> String -> Int -> IO (Maybe NS.Socket)
takeInsecureSocket man host port =
    I.atomicModifyIORef (mInsecure man) go
  where
    key = (host, port)
    go m = (Map.delete key m, Map.lookup key m)

putInsecureSocket :: Manager -> String -> Int -> NS.Socket -> IO ()
putInsecureSocket man host port sock = do
    msock <- I.atomicModifyIORef (mInsecure man) go
    maybe (return ()) NS.sClose msock
  where
    key = (host, port)
    go m = (Map.insert key sock m, Map.lookup key m)

-- | Create a new 'Manager' with no open connection.
newManager :: IO Manager
newManager = Manager <$> I.newIORef Map.empty

-- | Close all connections in a 'Manager'. Afterwards, the 'Manager' can be
-- reused if desired.
closeManager :: Manager -> IO ()
closeManager (Manager i) = do
    m <- I.atomicModifyIORef i $ \x -> (Map.empty, x)
    mapM_ NS.sClose $ Map.elems m

-- | Create a new 'Manager', call the supplied function and then close it.
withManager :: MonadControlIO m => (Manager -> m a) -> m a
withManager = liftIOOp $ bracket newManager closeManager
