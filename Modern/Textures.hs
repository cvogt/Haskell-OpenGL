module Textures where

import Data.Vector.Storable (unsafeWith)
import Control.Monad (liftM)
import Foreign hiding (unsafePerformIO)
import System.IO (IOMode(ReadMode), openBinaryFile, hSeek, 
                   SeekMode(RelativeSeek), Handle, hGetBuf)
import System.IO.Unsafe (unsafePerformIO)
import Data.List

import qualified Codec.Picture as Juicy
import qualified Codec.Picture.Types as JTypes

import Graphics.Rendering.OpenGL.Raw (GLuint)
import qualified Graphics.Rendering.OpenGL as GL
import Graphics.Rendering.OpenGL (PixelData(..), PixelFormat(..), Size(..), 
                                   DataType(..), ($=))

import Types


data Endian = LittleEndian | BigEndian
              deriving (Eq, Ord, Show)

loadGLTextures :: [FilePath] -> IO [GL.TextureObject]
loadGLTextures = loadGLTexturesIds 0

loadGLTexturesIds :: GLuint -> [FilePath] -> IO [GL.TextureObject]
loadGLTexturesIds i (file:others) = do
    cur <- loadGLTextureId i file
    rest <- loadGLTexturesIds (i+1) others
    return $ cur : rest
loadGLTexturesIds _ [] = return []

-- | TODO: This loads the files with an id of 0,
--   without accounting for previously loaded images.
loadGLTextureId :: GLuint -> FilePath -> IO GL.TextureObject
loadGLTextureId texId file = do
    (Image (Size w h) pd) <- bitmapLoad file
    texName <- liftM head (GL.genObjectNames 1)
    GL.textureBinding GL.Texture2D $= Just texName
    GL.textureFilter GL.Texture2D $= ((GL.Nearest, Nothing), GL.Nearest)
    GL.texImage2D GL.Texture2D GL.NoProxy (fromIntegral texId) GL.RGB' (GL.TextureSize2D w h) 0 pd
    return texName

loadGLImageId :: GLuint -> FilePath -> IO GL.TextureObject
loadGLImageId texId file = do
    (Image (Size w h) pd) <- juicyLoadImage file
    texName <- liftM head (GL.genObjectNames 1)
    GL.textureBinding GL.Texture2D $= Just texName
    GL.textureFilter GL.Texture2D $= ((GL.Nearest, Nothing), GL.Nearest)
    GL.texImage2D GL.Texture2D GL.NoProxy (fromIntegral texId) GL.RGB' (GL.TextureSize2D w h) 0 pd
    return texName

loadGLPngId :: GLuint -> FilePath -> IO GL.TextureObject
loadGLPngId texId file = do
    (Image (Size w h) pd) <- juicyLoadPng file
    texName <- liftM head (GL.genObjectNames 1)
    GL.textureBinding GL.Texture2D $= Just texName
    GL.textureFilter GL.Texture2D $= ((GL.Nearest, Nothing), GL.Nearest)
    GL.texImage2D GL.Texture2D GL.NoProxy (fromIntegral texId) GL.RGB' (GL.TextureSize2D w h) 0 pd
    return texName

juicyLoadImage :: FilePath -> IO Image
juicyLoadImage file =
    if "png" `isSuffixOf` file
        then juicyLoadPng file
    else if "jpg" `isSuffixOf` file || "jpeg" `isSuffixOf` file
        then juicyLoadJpeg file
    else if "bmp" `isSuffixOf` file
        then bitmapLoad file
    else
        putStrLn ("Unrecognized image format in juicyLoadImage: "
                    ++ file) 
        >> undefined

juicyLoadPng :: FilePath -> IO Image
juicyLoadPng file = do
    image <- Juicy.readPng file
    
    case image of
        Left err -> error err >> undefined
        Right (Juicy.ImageRGB8 (Juicy.Image w h dat)) ->
            unsafeWith dat $ \ptr ->
            return $ Image (GL.Size (fromIntegral w) (fromIntegral h))
                            (GL.PixelData GL.RGB UnsignedByte ptr)

juicyLoadJpeg :: FilePath -> IO Image
juicyLoadJpeg file = do
    image <- Juicy.readJpeg file
    
    case image of
        Left err -> error err >> undefined
        Right (Juicy.ImageYCbCr8 img) ->
            let (Juicy.Image w h dat) = JTypes.convertImage img :: Juicy.Image Juicy.PixelRGB8
            in unsafeWith dat $ \ptr ->
                return $ Image (GL.Size (fromIntegral w) (fromIntegral h))
                            (GL.PixelData GL.RGB UnsignedByte ptr)
        _ -> undefined

bitmapLoad :: String -> IO Image
bitmapLoad f = do
    handle <- openBinaryFile f ReadMode
    hSeek handle RelativeSeek 18
    width <- readInt handle
    putStrLn $ "Width of "++f++": "++show width
    height <- readInt handle
    putStrLn $ "Height of "++f++": "++show height
    planes <- readShort handle
    bpp <- readShort handle
    let size = width*height*(fromIntegral bpp `div` 8)
    hSeek handle RelativeSeek 24
    putStrLn $ "Planes = " ++ show planes
    bgrBytes <- (readBytes handle (fromIntegral size) :: IO (Ptr Word8))
    rgbBytes <- bgr2rgb bgrBytes (fromIntegral size)
    return $ Image (Size (fromIntegral width) $ fromIntegral height) $
            PixelData RGB UnsignedByte rgbBytes

endian :: Endian
endian = 
    let r = unsafePerformIO $
            allocaBytes 4 (\p -> do 
                pokeElemOff p 0 (0::Word8)
                pokeElemOff p 1 (1::Word8)
                pokeElemOff p 2 (2::Word8)
                pokeElemOff p 3 (3::Word8)
                peek (castPtr p) :: IO Int32)
         in case r of 50462976 -> LittleEndian
                      66051    -> BigEndian
                      _        -> undefined

bgr2rgb :: Ptr Word8 -> Int -> IO (Ptr Word8)
bgr2rgb p n = mapM_ 
    (\i -> do
        b <- peekElemOff p (i+0)
        g <- peekElemOff p (i+1)
        r <- peekElemOff p (i+2)
        pokeElemOff p (i+0) r
        pokeElemOff p (i+1) g
        pokeElemOff p (i+2) b) 
    [0,3..n-3]
    >> return p
                  
-- This is only needed if you're on PowerPC instead of x86
-- if you are on x86 use the following:
-- reverseBytes p _ = return p
reverseBytes :: Ptr Word8 -> Int -> IO (Ptr Word8)
reverseBytes p n | endian == BigEndian = 
                   do p' <- mallocBytes n
                      mapM_ (\i -> peekElemOff p i >>= pokeElemOff p' (n-i-1)) 
                            [0..n-1]
                      return p'
                 | endian == LittleEndian = do p' <- mallocBytes n
                                               copyBytes p' p n
                                               return p'
reverseBytes _ _ = undefined
                            
readBytes :: Storable a => Handle -> Int -> IO (Ptr a)
readBytes h n = do p <- mallocBytes n
                   _ <- hGetBuf h p n
                   return p

readShort :: Handle -> IO Word16
readShort h = do p <- readBytes h 2 :: IO (Ptr Word8)
                 p' <- reverseBytes (castPtr p) 2
                 free p
                 r <- peek (castPtr p')
                 free p'
                 return r

readInt :: Handle -> IO Int32
readInt h = do p <- readBytes h 4 :: IO (Ptr Word8)
               p' <- reverseBytes (castPtr p) 4
               free p
               r <- peek (castPtr p')
               free p'
               return r

