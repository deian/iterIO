
module Data.IterIO.Http where

import Control.Monad.Trans
import Data.Array.Unboxed
import Data.Bits
import qualified Data.ByteString.Lazy.Char8 as L8
import Data.ByteString.Internal (w2c, c2w)
import Data.Char
import Data.Int
import Data.Word
import Data.IterIO
import Data.IterIO.Parse
import Text.Printf

import System.IO

type S = L8.ByteString

pack :: String -> S
pack = L8.pack

unpack :: S -> String
unpack = L8.unpack

eord :: (Enum e) => Char -> e
eord = toEnum . ord

optional :: (ChunkData t, Monad m) => Iter t m a -> Iter t m ()
optional iter = skipI iter <|> return ()

-- | Secton 19.3 of RFC2616: "The line terminator for message-header
-- fields is the sequence CRLF.  However, we recommend that
-- applications, when parsing such headers, recognize a single LF as a
-- line terminator and ignore the leading CR."
crlf :: (Monad m) => Iter S m Word8
crlf = char '\r' *> char '\n' <|> char '\n'

spaces :: (Monad m) => Iter S m ()
spaces = skipWhile1I (\c -> c == eord ' ' || c == eord '\t')
         <?> "spaces"

lws :: (Monad m) => Iter S m S
lws = optional crlf >> L8.singleton ' ' <$ spaces <?> "linear white space"

noctl :: (Monad m) => Iter S m S
noctl = while1I (\c -> c >= 0x20 && c < 0x7f) <?> "non-control characters"

text :: (Monad m) => Iter S m S
text = concat1I (noctl <|> lws) <?> "text (Data.IterIO.Http)"

text_except :: (Monad m) => String -> Iter S m S
text_except except = concat1I (while1I ok <|> lws)
    where
      ok c = c >= 0x20 && c < 0x7f && not (w2c c `elem` except)

hexTab :: UArray Word8 Int8
hexTab = listArray (0,127) $ fmap digit ['\0'..'\177']
    where
      digit c | isHexDigit c = toEnum $ digitToInt c
              | otherwise    = -1

-- | Return one hex digit
hex :: (Monad m) => Iter S m Int
hex = headLikeI >>= digit <?> "hex digit"
    where
      digit c = case hexTab ! c of
                  -1 -> expectedI "hex digit"
                  n  -> return $ fromIntegral n

-- | Parse a raw hexadecimal number (no "0x..." prefix).
hexInt :: (Monad m) => Iter S m Int
hexInt = foldM1I digit 0 hex
    where
      maxok = maxBound `shiftR` 4
      digit n d | n > maxok = throwI (IterParseErr "hex integer too large")
                | otherwise = return $ (n `shiftL` 4) .|. d

tokenTab :: UArray Word8 Bool
tokenTab = listArray (0,127) $ fmap isTokenChar [0..127]
    where
      isTokenChar c = c > 0x20 && c < 0x7f && not (elem (chr c) separators)
      separators = "()<>@,;:\\\"/[]?={} \t\177"

token :: (Monad m) => Iter S m S
token = while1I (tokenTab !) <?> "token"

quoted_pair :: (Monad m) => Iter S m S
quoted_pair = char '\\' <:> headLikeI <:> nil

comment :: (Monad m) => Iter S m S
comment = char '('
          <:> concatI (text_except "()" <|> quoted_pair <|> comment)
          <++> string ")"
          <?> "comment"

quoted_string :: (Monad m) => Iter S m S
quoted_string = char '"'
                <:> concatI (text_except "\"" <|> quoted_pair)
                <++> string "\""

inumToChunks :: (Monad m) => EnumI S S m a
inumToChunks = enumI $ iterToCodec doChunk
    where
      doChunk = do
        Chunk s eof <- chunkI
        let len       = L8.length s
            chunksize = pack $ printf "%x\r\n" len
            trailer   = if eof && len > 0
                        then pack "\r\n0\r\n\r\n"
                        else pack "\r\n"
        return $ L8.append chunksize $ L8.append s trailer

inumFromChunks :: (Monad m) => EnumI S S m a
inumFromChunks = enumI getsize
    where
      osp = skipWhileI $ \c -> c == eord ' ' || c == eord '\t'
      chunk_ext_val = do char '"'; osp; token <|> quoted_string; osp
      chunk_ext = do char ';'; osp; token; osp; optional chunk_ext_val

      getsize = do
        size <- hexInt
        osp
        skipMany chunk_ext
        crlf
        if size > 0 then getdata size else gettrailer

      getdata n = do
        s <- stringMaxI n
        let n' = n - fromIntegral (L8.length s)
        return $ CodecF (if n' > 0 then getdata n' else crlf >> getsize) s

      gettrailer = do
        skipMany (noctl >> crlf)
        crlf
        return $ CodecE L8.empty


hTTPvers :: (Monad m) => Iter S m (Int, Int)
hTTPvers = do
  string "HTTP/"
  maj <- whileI (isDigit . w2c) >>= readI
  char '.'
  min <- whileI (isDigit . w2c) >>= readI
  return (maj, min)

hdrLine :: (Monad m) => Iter S m S
hdrLine = lineI <++> foldrI L8.append L8.empty contLine
    where contLine = lws <++> lineI




hdr :: (Monad m) => Iter S m [S]
hdr = many hdrLine


lineChar :: (Monad m) => Iter S m Word8
lineChar = satisfy (\c -> c /= eord '\r' && c /= eord '\n')

linesI :: (Monad m) => Iter L8.ByteString m [L8.ByteString]
linesI = many1 lineChar `sepBy` crlf

put :: L8.ByteString -> IO ()
put = Prelude.putStrLn . show . L8.unpack

enumHdr :: (Monad m) => EnumO L8.ByteString m a
enumHdr = enumPure $ L8.pack $ "Header: value\r\n   cont\r\n"
          ++ "Test: a header\r\n               with extra line\r\n"
          ++ "Test2: another header\n"
          ++ "Test3: a fourth\r\n"

main :: IO ()
-- main = enumHdr |$ hdr >>= mapM_ L8.putStrLn
main = enumHandle stdin |$
       inumToChunks
        ..| inumLog "chunks.log" True 
        ..| inumFromChunks
        ..| handleI stdout
           

