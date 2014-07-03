{-# LANGUAGE TypeFamilies #-}
module Engine.Core.WorldCreator (
    Proto(..),
    fromObj, modify,
    createFromProto,
    defaultWorld, createWorld,
    defaultSettings
) where

import Control.Monad (void)
import Control.Applicative ((<$>))
import Data.Maybe (isJust, fromJust)
import System.FilePath ((</>))
import Data.Vec ((:.)(..))

import Unsafe.Coerce (unsafeCoerce)

import Physics.Bullet.Raw.Types
    (Vec3(..), Transform(..), idmtx)

import Graphics.Rendering.OpenGL.Raw (GLfloat)

import Engine.Core.Types
    (World(..), WorldState(..), Graphics(..),
     Entity(..),
     emptyGraphics, emptyWorldState)
import Engine.Graphics.Window (Window(..), defaultWindow, openWindow)
import Engine.Object.Player (mkPlayer)
import Engine.Object.Octree (Octree(..), createOctreeFromAABBs)
import Engine.Core.World (getWorldTime)
import Engine.Mesh.ObjLoader (loadObjObject)
import Engine.Terrain.Generator (generateTerrain)
import Engine.Graphics.Graphics (makeFrameBuffer)
import Engine.Graphics.Shaders (loadProgram)
import Engine.Graphics.Shadows (makeShadowFrameBuffer)
import Engine.Terrain.Noise (Simplex(..))
import Engine.Terrain.Generator (Terrain(..))
import Engine.Mesh.AABB (AABB(..))
import Engine.Graphics.Graphics (initGL)
import Engine.Bullet.Bullet
    (Physics, AttrOp(..), mkPhysics, set, worldTransform)

data family Proto a

data instance Proto (World t) =
    ProtoWorld {
        settingsSimplex :: Maybe Simplex,
        settingsTerrainShaders :: (FilePath, FilePath),
        settingsTerrainTexture :: Maybe FilePath,
        settingsObjs :: [Proto (Entity t)],
        settingsWholeAABB :: AABB,
        settingsWindow :: Proto Window,
        settingsPostShaders :: [(FilePath, FilePath)],
        settingsShadowShader :: (FilePath, FilePath),
        settingsShaderAttribs :: [(String, IO [GLfloat])]
    }

data instance Proto (Entity t) =
    FromObj FilePath FilePath FilePath [Entity t -> Entity t] t

data instance Proto Window = ProtoWindow Window

-- | Create a "ProtoObject" that contains
--   instructions to parse a file and create
--   a "GameObject".
fromObj :: FilePath -> FilePath -> FilePath -> t -> Proto (Entity t)
fromObj file vert frag attr = FromObj file vert frag [] attr

-- | Add a function that will modify the
--   GameObject after it is loaded.
modify :: (Entity t -> Entity t) ->
          Proto (Entity t) ->
          Proto (Entity t)
modify f (FromObj file vert frag mods attr) =
    FromObj file vert frag (f:mods) attr

createFromProto :: Physics -> Proto (Entity t) -> IO (Entity t)
createFromProto phys (FromObj file vert frag mods attr) = do
    entity <- (\obj -> foldr (\f o -> f o) obj mods) <$>
                loadObjObject phys vert frag attr file
    let x :. y :. z :. () = entityPosition entity
        pos = Vec3 (uC x) (uC y) (uC z)
        trans = Transform idmtx pos
    void $ set (entityRigidBody entity) [worldTransform := trans]
    return entity
  where
    uC = unsafeCoerce

defaultSettings :: Proto (World ())
defaultSettings =
    ProtoWorld
        (Just $ Simplex 0 (200, 200) (0, 0) 1 1 20 10 undefined)
        (".." </> "res" </> "shaders" </> "correct_v.glsl",
         ".." </> "res" </> "shaders" </> "correct_f.glsl")
        (Just $ ".." </> "res" </> "textures" </> "grass.jpg")
        [fromObj (".." </> "res" </> "objects" </> "wow" </> "wow.obj")
         (".." </> "res" </> "shaders" </> "correct_v.glsl")
         (".." </> "res" </> "shaders" </> "correct_f.glsl") (),
         modify (\x -> x{entityPosition = (-20) :. (-20) :. (-5) :. ()}) $
         fromObj (".." </> "res" </> "objects" </> "ibanez" </> "ibanez.obj")
         (".." </> "res" </> "shaders" </> "correct_v.glsl")
         (".." </> "res" </> "shaders" </> "correct_f.glsl") ()]
        (AABB (-100) 200)
        (ProtoWindow defaultWindow)
        {-[(".." </> "res" </> "shaders" </> "postprocessing"
          </> "passthrough" </> "passthrough_v.glsl",
          ".." </> "res" </> "shaders" </> "postprocessing"
          </> "passthrough" </> "passthrough_f.glsl")]-}
        [(".." </> "res" </> "shaders" </> "postprocessing" </> "dof"  </> "dof_v.glsl",
          ".." </> "res" </> "shaders" </> "postprocessing" </> "dof"  </> "dof_f.glsl"),
         (".." </> "res" </> "shaders" </> "postprocessing" </> "fxaa" </> "fxaa_v.glsl",
          ".." </> "res" </> "shaders" </> "postprocessing" </> "fxaa" </> "fxaa_f.glsl")]
         (".." </> "res" </> "shaders" </> "shadow" </> "shadow_v.glsl",
          ".." </> "res" </> "shaders" </> "shadow" </> "shadow_f.glsl")
        [("lightPos", return [0.0, 10.0, 0.0])]

defaultWorld :: World t
defaultWorld =
    World undefined []
          Nothing (OLeaf (AABB 0 0) [] 0)
          undefined
          emptyGraphics
          emptyWorldState

createWorld :: Proto (World t) -> IO (World t)
createWorld settings = do
    physics <- mkPhysics
    window <- createWindow $ settingsWindow settings
    objects <- mapM (createFromProto physics) $ settingsObjs settings
    terrain <- createTerrain settings
    player <- mkPlayer physics

    let octree = createOctreeFromAABBs
                (settingsWholeAABB settings)
                objects

    fb <- makeFrameBuffer $ windowSize window
    postShaders <- mapM (uncurry loadProgram) $ settingsPostShaders settings

    sfb <- makeShadowFrameBuffer $ windowSize window
    let (shV, shF) = settingsShadowShader settings
    shadowShader <- loadProgram shV shF

    let graphics = Graphics
            (settingsShaderAttribs settings)
            (fb, postShaders)
            (sfb, shadowShader)

    t <- getWorldTime
    let state = WorldState t 0 False window

    return defaultWorld {
            worldPlayer = player,
            worldEntities = objects,
            worldTerrain = terrain,
            worldOctree = octree,
            worldPhysics = physics,
            worldGraphics = graphics,
            worldState = state
        }

createWindow :: Proto Window -> IO Window
createWindow (ProtoWindow win) = do
    window <- openWindow win
    initGL $ fromJust $ windowInner window
    return window

createTerrain :: Proto (World t) -> IO (Maybe Terrain)
createTerrain settings =
    let msimplex = settingsSimplex settings
        (vert, frag) = settingsTerrainShaders settings
    in if isJust msimplex
        then
            let simplex = fromJust msimplex
                (w, _) = simpDimensions simplex
            in Just <$>
                generateTerrain vert frag
                    (fromIntegral w) (simpSpacing simplex)
                    (simpOctaves simplex)
                    (simpWavelength simplex)
                    (simpIntensity simplex)
                    (settingsTerrainTexture settings)
        else return Nothing