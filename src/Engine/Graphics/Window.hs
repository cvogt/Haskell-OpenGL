module Engine.Graphics.Window (
    defaultWindow, Window(..),
    openWindow, shutdown
) where

import Data.Default
import System.Exit (exitSuccess)

import qualified Graphics.UI.GLFW as GLFW
import Graphics.Rendering.OpenGL.Raw (GLint)

data Window = Window {
    windowHints :: [GLFW.WindowHint],
    windowTitle :: String,
    windowSize :: (GLint, GLint),
    windowInner :: Maybe GLFW.Window
} deriving (Show)

instance Default Window where
    def = defaultWindow

defaultWindow :: Window
defaultWindow =
    Window
        [GLFW.WindowHint'RefreshRate 60,
         GLFW.WindowHint'Samples 4]
        "GLFW Window"
        (800, 600)
        Nothing

openWindow :: Window -> IO Window
openWindow window = do
    let (w, h) = windowSize window

    _ <- GLFW.init

    -- Apply window hints.
    mapM_ GLFW.windowHint $ windowHints window

    Just win <- GLFW.createWindow
                    (fromIntegral w)
                    (fromIntegral h)
                    (windowTitle window) Nothing Nothing
    GLFW.setWindowPos win 100 50
    GLFW.makeContextCurrent (Just win)

    -- Enable VSync
    GLFW.swapInterval 1

    return $ window{windowInner = Just win}

shutdown :: GLFW.WindowCloseCallback
shutdown win = do
    GLFW.destroyWindow win
    GLFW.terminate
    _ <- exitSuccess
    return ()
