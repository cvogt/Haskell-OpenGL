module Main where

import Data.Time (diffUTCTime)
import Control.Monad (unless)

import qualified Graphics.UI.GLFW as GLFW

import Graphics.Rendering.OpenGL.Raw

import Engine.Graphics.Graphics
import TestVals
import Engine.Object.GameObject
import Engine.Graphics.Window
import Engine.Core.Vec
import Engine.Core.World
import Engine.Graphics.Shaders
import Engine.Graphics.Textures

main :: IO ()
main = do
    -- Initialize GLFW, create a window, open it.
    window <- openWindow defaultWindow
    let Just win = windowInner window

    -- Perform some intitial OpenGL configurations.
    initGL win

    -- Create default world, set the window.
    tmp <- mkWorldFast
    let world = tmp{
        worldState = (worldState tmp){stateWindow = window}}

    -- Register the function called whe our window is resized.
    GLFW.setFramebufferSizeCallback win (Just resizeScene)

    -- Make cursor Hidden.
    GLFW.setCursorInputMode win GLFW.CursorInputMode'Disabled

    qShader <- loadProgram
        --"shaders/postprocessing/bumpy/bumpy.vert"
        --"shaders/postprocessing/bumpy/bumpy.frag"
        "shaders/postprocessing/invert/invert.vert"
        "shaders/postprocessing/invert/invert.frag"
    fb <- makeFrameBuffer (worldState world)

    -- Begin game loop.
    loop win world fb qShader
    -- Delete stuff left in OpenGL.
    cleanupObjects $ worldEntities world
    -- Shutdown when game loop is done.
    shutdown win

    where
        --loop :: GLFW.Window -> World t -> IO ()
        loop win world fb qs = do
            -- Check if any events have occured.
            GLFW.pollEvents

            -- Perform logic update on the world and render.
            newWorld <- updateStep win world >>=
                    (\w -> renderStep w fb qs win)

            -- Swap back and front buffer.
            GLFW.swapBuffers win

            shouldClose <- GLFW.windowShouldClose win
            unless shouldClose $
                loop win newWorld fb qs

renderStep :: World t -> FrameBuffer -> GLuint -> GLFW.Window -> IO (World t)
renderStep world fb s _ =
    renderWorldFB fb world s

updateStep :: GLFW.Window -> World t -> IO (World t)
updateStep win world = do
    let wState = worldState world

    GLFW.setCursorInputMode win $ if statePaused wState
        then GLFW.CursorInputMode'Normal
    else GLFW.CursorInputMode'Disabled

    -- Update the world time and delta.
    worldTime <- getWorldTime
    let delta = realToFrac $ diffUTCTime worldTime (stateTime wState)
        newState = wState{
        stateTime = worldTime, stateDelta = delta}

    -- Update player input
    player <- updatePlayerInput win $ worldPlayer world

    -- Update player
    let newWorld = playerUpdate player
                world{worldPlayer = player, worldState = newState}
        tmpPlayer = worldPlayer newWorld
        -- Set mouse delta movement to 0.
        pin = (playerInput tmpPlayer){inputMouseDelta = Vec2 0 0}
        newPlayer = tmpPlayer{playerInput = pin}

    return $ (updateWorld newWorld){
        worldPlayer = newPlayer
    }

updatePlayerInput :: GLFW.Window -> GameObject t -> IO (GameObject t)
updatePlayerInput win player@(Player{}) = do
    let input = playerInput player
    newIn <- updateInput win input
    return $ player{
        playerInput = newIn
    }
updatePlayerInput _ _ =
    error $ "Main.updatePlayerInput can only"
        ++ " be used on Players."

updateInput :: GLFW.Window -> Input t -> IO (Input t)
updateInput win input = do
    --checkForEsc win
    let mousePos = inputLastMousePos input
    newKeys <- loopThrough win $ inputKeys input
    newMousePos <- mouseUpdate win
    return input {
        inputKeys = newKeys,
        inputMouseDelta = newMousePos - mousePos
    }

    where
    loopThrough ::
        GLFW.Window ->
        [(GLFW.Key, GLFW.KeyState, GLFW.KeyState, World t -> World t)] ->
        IO [(GLFW.Key, GLFW.KeyState, GLFW.KeyState, World t -> World t)]
    loopThrough w ((key, desired, lastState, func) : others) = do
        returnedState <- GLFW.getKey w key

        let keyState
                | returnedState == GLFW.KeyState'Released =
                    GLFW.KeyState'Released
                | returnedState == GLFW.KeyState'Pressed &&
                    (lastState == GLFW.KeyState'Pressed ||
                     lastState == GLFW.KeyState'Repeating) =
                    GLFW.KeyState'Repeating
                | otherwise = GLFW.KeyState'Pressed

        let curVal = (key, desired, keyState, func)
        restVal <- loopThrough win others
        return $ curVal : restVal
    loopThrough _ [] = return []

    mouseUpdate :: GLFW.Window -> IO (Vec2 GLfloat)
    mouseUpdate w = do
        (x, y) <- GLFW.getCursorPos w
        return $ Vec2 (realToFrac x) (realToFrac y)
