module TestVals (
    mkWorld, mkWorldState, mkWorldFast
) where

import Control.Applicative ((<$>), (<*>))
import System.FilePath ((</>))

import Graphics.Rendering.OpenGL.Raw

import Engine.Object.Player
import Engine.Model.ObjLoader
import Engine.Terrain.Generator
import Engine.Core.Vec
import Engine.Core.World
import Engine.Model.Model
import Engine.Graphics.Window
import Engine.Graphics.Shaders
import Engine.Graphics.Framebuffer

mkWorldFast :: IO (World ())
mkWorldFast = do
    state <- mkWorldState
    passShader <- loadProgram
        "shaders/postprocessing/passthrough/passthrough.vert"
        "shaders/postprocessing/passthrough/passthrough.frag"
{-
    fishShader <- loadProgram
        "shaders/postprocessing/fisheye/fisheye.vert"
        "shaders/postprocessing/fisheye/fisheye.frag"
-}
{-
    sobelShader <- loadProgram
        "shaders/postprocessing/sobel/sobel.vert"
        "shaders/postprocessing/sobel/sobel.frag"
-}
{-
    posterShader <- loadProgram
        "shaders/postprocessing/poster/poster.vert"
        "shaders/postprocessing/poster/poster.frag"
-}
{-
    pixelateShader <- loadProgram
        "shaders/postprocessing/pixelate/pixelate.vert"
        "shaders/postprocessing/pixelate/pixelate.frag"
-}
{-
    invertShader <- loadProgram
        "shaders/postprocessing/invert/invert.vert"
        "shaders/postprocessing/invert/invert.frag"
-}

    let winDimensions = windowSize $ stateWindow state

    --fb <- makeFrameBuffer winDimensions
    let fb = FB 0 0 (0, 0) 0 0
    mkWorld fb [passShader]

mkWorld :: Framebuffer -> [GLuint] -> IO (World ())
mkWorld fb shaders = do
    state <- mkWorldState
    obja <- mkObj
    objb <- mkObj2
    objc <- mkObj3
    return $ World mkPlayer [obja, objb, objc]
             [("lightPos", return [0.0, 10.0, 0.0])] (fb, shaders) state

mkWorldState :: IO WorldState
mkWorldState = do
    t <- getWorldTime
    return $ WorldState t 0 False defaultWindow

mkObj :: IO (GameObject ())
mkObj =
    PureEntity (Vec3 10 3 10) id <$> mkModel <*> return ()

mkObj2 :: IO (GameObject ())
mkObj2 =
    PureEntity (Vec3 0 0 0) id <$> mkTerrain <*> return ()

mkObj3 :: IO (GameObject ())
mkObj3 =
    --PureEntity (Vec3 0 (-20) 0) id <$> mkModel3 <*> return ()
    PureEntity (Vec3 0 0 50) id <$> mkModel3 <*> return ()

{-
eMove :: GameObject t -> GameObject t
eMove pe@(PureEntity{}) =
    moveObject pe (Vec3 0.005 0 0)
eMove a = a
-}

mkModel :: IO Model
mkModel =
    loadObjModel ("res" </> "objects" </> "wow" </> "wow.obj")
                               mainVertShader
                               mainFragShader

mkTerrain :: IO Model
mkTerrain = genSimplexModel
            mainVertShader
            mainFragShader
            50
            1
            1
            20
            10

mkModel3 :: IO Model
mkModel3 = 
    loadObjModel ("res" </> "objects" </> "isengard" </> "isengard.obj")
                               mainVertShader
                               mainFragShader

mainVertShader :: String
--mainVertShader = "shaders" </> "correct.vert"
mainVertShader = "shaders" </> "shadow" </> "shadow2.vert"

mainFragShader :: String
--mainFragShader = "shaders" </> "correct.frag"
mainFragShader = "shaders" </> "shadow" </> "shadow2.frag"
