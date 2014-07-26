{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Engine.Graphics.GLSL where

import GHC.TypeLits
import Data.Vec (Vec2, Vec3, Vec4, Mat44, identity)

import Control.Applicative (Applicative)
import Control.Monad.Writer

import Data.String (fromString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C

import qualified Graphics.Rendering.OpenGL as GL
import Graphics.Rendering.OpenGL.Raw (GLfloat)

-- TODO: Use ByteString builder,
--       there are many inefficient
--       appends that could be /O(1)/.

---------------
-- Execution --
---------------

generateGLSL :: ShaderM s t a -> B.ByteString
generateGLSL = programBString . execShaderM

execShaderM :: ShaderM s t a -> [GLSLUnit]
execShaderM = fst . runShaderM

evalShaderM :: ShaderM s t a -> GLSLInfo t
evalShaderM = snd . runShaderM

runShaderM :: ShaderM s t a -> ([GLSLUnit], GLSLInfo t)
runShaderM = execWriter . sInnerShaderM

------------------
-- Shader types --
------------------

type VertexShaderM t a = ShaderM GL.VertexShader t a
type GeometryShaderM t a = ShaderM GL.GeometryShader t a
type FragmentShaderM t a = ShaderM GL.FragmentShader t a

newtype ShaderM s t a = ShaderM {
    sInnerShaderM :: Writer ([GLSLUnit], GLSLInfo t) a
    }
    deriving (Functor, Applicative, Monad)
instance MonadWriter ([GLSLUnit], GLSLInfo t) (ShaderM s t) where
    listen (ShaderM glsl) = ShaderM $ listen glsl
    pass (ShaderM glsl) = ShaderM $ pass glsl
    tell = ShaderM . tell
    writer = ShaderM . writer

class ShaderType (s :: GL.ShaderType) where
    type InArgs s gt (t :: Symbol) :: *
    type UniformArgs s gt (t :: Symbol) :: *

    layoutDecl :: (KnownSymbol t, GPU t, KnownSymbol q) =>
        [B.ByteString] -> SymbolProxy q -> SymbolProxy t ->
        B.ByteString -> ShaderM s gt (Value q t)

    layoutIn :: (KnownSymbol t, GPU t) =>
        [B.ByteString] -> SymbolProxy t -> InArgs s gt t ->
        ShaderM s gt (Value "in" t)
    layoutUniform :: (KnownSymbol t, GPU t) =>
        [B.ByteString] -> SymbolProxy t -> UniformArgs s gt t ->
        ShaderM s gt (Value "uniform" t)
    layoutOut :: (KnownSymbol t, GPU t) =>
        [B.ByteString] -> SymbolProxy t -> B.ByteString ->
        ShaderM s gt (Value "out" t)

    none :: (KnownSymbol t, GPU t) =>
        SymbolProxy t -> B.ByteString ->
        ShaderM s gt (Value "none" t)
    none = layoutDecl [] SProxy

    inn :: (KnownSymbol t, GPU t) =>
        SymbolProxy t -> InArgs s gt t -> ShaderM s gt (Value "in" t)
    inn = layoutIn []

    uniform :: (KnownSymbol t, GPU t) =>
        SymbolProxy t -> UniformArgs s gt t -> ShaderM s gt (Value "uniform" t)
    uniform = layoutUniform []

    out :: (KnownSymbol t, GPU t) =>
        SymbolProxy t -> B.ByteString -> ShaderM s gt (Value "out" t)
    out = layoutOut []

instance ShaderType GL.VertexShader where
    type InArgs GL.VertexShader gt t = (B.ByteString, gt -> [CPU t])
    type UniformArgs GL.VertexShader gt t = (B.ByteString, gt -> CPU t)

    layoutDecl layouts qualifier glType name = do
        ltell $ Decl (Layout layouts) (qualifierSymbol qualifier) (typeSymbol glType) name
        return $ Value name qualifier glType

    layoutIn layouts glType (name, values) = do
        logIn glType values name
        layoutDecl layouts SProxy glType name

    layoutUniform layouts glType (name, value) = do
        logUniform glType value name
        layoutDecl layouts SProxy glType name

    layoutOut layouts glType name = do
        logOut glType name
        layoutDecl layouts SProxy glType name

instance ShaderType GL.GeometryShader where
    type InArgs GL.GeometryShader gt t = B.ByteString
    type UniformArgs GL.GeometryShader gt t = (B.ByteString, gt -> CPU t)

    layoutDecl layouts qualifier glType name = do
        ltell $ Decl (Layout layouts) (qualifierSymbol qualifier) (typeSymbol glType) name
        ShaderM . return $ Value name qualifier glType

    layoutIn layouts glType name = do
        logIn glType (const []) name
        layoutDecl layouts SProxy glType name

    layoutUniform layouts glType (name, value) = do
        logUniform glType value name
        layoutDecl layouts SProxy glType name

    layoutOut layouts glType name = do
        logOut glType name
        layoutDecl layouts SProxy glType name

instance ShaderType GL.FragmentShader where
    type InArgs GL.FragmentShader gt t = B.ByteString
    type UniformArgs GL.FragmentShader gt t = (B.ByteString, gt -> CPU t)

    layoutDecl layouts qualifier glType name = do
        ltell $ Decl (Layout layouts) (qualifierSymbol qualifier) (typeSymbol glType) name
        return $ Value name qualifier glType

    layoutIn layouts glType name = do
        logIn glType (const []) name
        layoutDecl layouts SProxy glType name

    layoutUniform layouts glType (name, value) = do
        logUniform glType value name
        layoutDecl layouts SProxy glType name

    layoutOut layouts glType name = do
        logOut glType name
        layoutDecl layouts SProxy glType name

-------------------
-- Logging Stuff --
-------------------

--type ShaderM s t a = Writer ([GLSLUnit], GLSLInfo t) a

data GLSLInfo t = GLSLInfo [In t] [Uniform t] [Out]

instance Monoid (GLSLInfo t) where
    mempty = GLSLInfo [] [] []
    mappend (GLSLInfo in1 uni1 out1) (GLSLInfo in2 uni2 out2) =
        GLSLInfo (in1 ++ in2) (uni1 ++ uni2) (out1 ++ out2)

inInfo :: In t -> GLSLInfo t
inInfo i = GLSLInfo [i] [] []

uniformInfo :: Uniform t -> GLSLInfo t
uniformInfo u = GLSLInfo [] [u] []

outInfo :: Out -> GLSLInfo t
outInfo o = GLSLInfo [] [] [o]

data In t =
    InFloat (t -> [GLfloat]) Name
  | InInt (t -> [Int]) Name
  | InVec2 (t -> [Vec2 GLfloat]) Name
  | InVec3 (t -> [Vec3 GLfloat]) Name
  | InVec4 (t -> [Vec4 GLfloat]) Name
  -- Unlikely, but...
  | InMat4 (t -> [Mat44 GLfloat]) Name

data Sampler2D = Sampler2DInfo GL.TextureObject GL.TextureUnit

data Uniform t =
    UniformFloat (t -> GLfloat) Name
  | UniformInt (t -> Int) Name
  | UniformVec2 (t -> Vec2 GLfloat) Name
  | UniformVec3 (t -> Vec3 GLfloat) Name
  | UniformVec4 (t -> Vec4 GLfloat) Name
  | UniformMat4 (t -> Mat44 GLfloat) Name
  | UniformSampler2D (t -> Sampler2D) Name

data Out =
    OutFloat Name
  | OutInt Name
  | OutBool Name
  | OutVec2 Name
  | OutVec3 Name
  | OutVec4 Name
  | OutMat4 Name
  | OutSampler2D Name
  deriving (Show, Eq)

class GPU (a :: Symbol) where
    type CPU a :: *
    inConstr :: SymbolProxy a -> ((t -> [CPU a]) -> Name -> GLSLInfo t)
    uniformConstr :: SymbolProxy a -> ((t -> CPU a) -> Name -> GLSLInfo t)
    outConstr :: SymbolProxy a -> (Name -> GLSLInfo t)

    logIn :: SymbolProxy a -> (t -> [CPU a]) -> Name -> ShaderM s t ()
    logIn proxy values = rtell . inConstr proxy values
    logUniform :: SymbolProxy a -> (t -> CPU a) -> Name -> ShaderM s t ()
    logUniform proxy value = rtell . uniformConstr proxy value
    logOut :: SymbolProxy a -> Name -> ShaderM s t ()
    logOut proxy = rtell . outConstr proxy

instance GPU "int" where
    type CPU "int" = Int
    inConstr _ values = inInfo . InInt values
    uniformConstr _ value = uniformInfo . UniformInt value
    outConstr _ = outInfo . OutInt

instance GPU "float" where
    type CPU "float" = GLfloat
    inConstr _ values = inInfo . InFloat values
    uniformConstr _ value = uniformInfo . UniformFloat value
    outConstr _ = outInfo . OutFloat

instance GPU "vec2" where
    type CPU "vec2" = Vec2 GLfloat
    inConstr _ values = inInfo . InVec2 values
    uniformConstr _ value = uniformInfo . UniformVec2 value
    outConstr _ = outInfo . OutVec2
instance GPU "vec3" where
    type CPU "vec3" = Vec3 GLfloat
    inConstr _ values = inInfo . InVec3 values
    uniformConstr _ value = uniformInfo . UniformVec3 value
    outConstr _ = outInfo . OutVec3
instance GPU "vec4" where
    type CPU "vec4" = Vec4 GLfloat
    inConstr _ values = inInfo . InVec4 values
    uniformConstr _ value = uniformInfo . UniformVec4 value
    outConstr _ = outInfo . OutVec4

instance GPU "mat4" where
    type CPU "mat4" = Mat44 GLfloat
    inConstr _ values = inInfo . InMat4 values
    uniformConstr _ value = uniformInfo . UniformMat4 value
    outConstr _ = outInfo . OutMat4

instance GPU "sampler2D" where
    type CPU "sampler2D" = Sampler2D
    inConstr _ _ _ = error "ShaderM.inConstr: sampler2D cannot be an in var."
    uniformConstr _ value = uniformInfo . UniformSampler2D value
    outConstr _ = outInfo . OutSampler2D

-----------
-- Types --
-----------

data GLSLUnit =
    Version B.ByteString
  | Decl Layout Qualifier Type Name
  | AssignStatement Name B.ByteString
  deriving Eq

type Name = B.ByteString

data SymbolProxy (a :: Symbol) = SProxy
data NatProxy (a :: Nat) = NProxy

data Value (q :: Symbol) (t :: Symbol) =
    Value Name (SymbolProxy q) (SymbolProxy t)

data Array (l :: Nat) (q :: Symbol) (t :: Symbol) =
    Array Name (NatProxy l) (SymbolProxy q) (SymbolProxy t)

data Expression (t :: Symbol) =
    Expression B.ByteString (SymbolProxy t)

newtype Layout = Layout [B.ByteString]
  deriving (Show, Eq, Monoid)

data Arg = forall a. (HasBString a, ReadableQ a) => Arg a

pack :: (HasBString a, ReadableQ a) => a -> Arg
pack = Arg

-- | Representation of ShaderM qualifiers in
--   Haskell value level.
data Qualifier =
    Out
  | In
  | Uniform
  | None
  deriving Eq

type QualifierP = SymbolProxy

-- = Representation of ShaderM qualifiers in
--   Haskell type level, using TypeLits.
outp :: QualifierP "out"
outp = SProxy
inp :: QualifierP "in"
inp = SProxy
uniformp :: QualifierP "uniform"
uniformp = SProxy
nonep :: QualifierP "none"
nonep = SProxy

-- | Representation of ShaderM s types in
--   Haskell value level.
data Type =
    Int
  | UInt
  | Float
  | Mat4
  | Vec4
  | Vec3
  | Vec2
  | Sampler2D
  deriving Eq

type TypeP = SymbolProxy

-- = Representation of ShaderM s types in
--   Haskell type level, using TypeLits.
int :: TypeP "int"
int = SProxy
uint :: TypeP "uint"
uint = SProxy
float :: TypeP "float"
float = SProxy
mat4 :: TypeP "mat4"
mat4 = SProxy
vec3 :: TypeP "vec3"
vec3 = SProxy
vec2 :: TypeP "vec2"
vec2 = SProxy
vec4 :: TypeP "vec4"
vec4 = SProxy
sampler2D :: TypeP "sampler2D"
sampler2D = SProxy

-- = TypeLits to B.ByteString stuff.

qualifierSymbol :: KnownSymbol q => SymbolProxy q -> Qualifier
qualifierSymbol q =
    case symbolVal q of
        "uniform" -> Uniform
        "in" -> In
        "out" -> Out
        "none" -> None
        _ -> error "Primitive.toTypeQ"

typeSymbol :: KnownSymbol t => SymbolProxy t -> Type
typeSymbol t =
    case symbolVal t of
        "int" -> Int
        "uint" -> UInt
        "float" -> Float
        "mat4" -> Mat4
        "vec4" -> Vec4
        "vec3" -> Vec3
        "vec2" -> Vec2
        "sampler2D" -> Sampler2D
        _ -> error "Primitive.toTypeT"

---------------------
-- BShow instances --
---------------------

class BShow a where
    bshow :: a -> B.ByteString

instance BShow Type where
    bshow Int = "int"
    bshow UInt = "uint"
    bshow Float = "float"
    bshow Mat4 = "mat4"
    bshow Vec2 = "vec2"
    bshow Vec3 = "vec3"
    bshow Vec4 = "vec4"
    bshow Sampler2D = "sampler2D"

instance BShow Qualifier where
    bshow In = "in"
    bshow Out = "out"
    bshow Uniform = "uniform"
    bshow None = B.empty

instance BShow Layout where
    bshow (Layout layouts)
        | not . null $ layouts =
            "layout" `B.append` paren (B.intercalate ", " layouts)
            `B.append` " "
        | otherwise = B.empty

instance BShow GLSLUnit where
    bshow (Version v) = "#version " `B.append` v `B.append` "\n"
    bshow (Decl layout None glType name) =
        bshow layout `B.append`
        bshow glType `B.append` " " `B.append` name `B.append`
        " = " `B.append` defaultValue glType `B.append`
        ";\n"
    bshow (Decl layout qualifier glType name) =
        bshow layout `B.append`
        bshow qualifier `B.append` " " `B.append`
        bshow glType `B.append` " " `B.append`
        name `B.append` ";\n"
    bshow (AssignStatement a b) =
        a `B.append` " = " `B.append` b `B.append` ";\n"

defaultValue :: Type -> B.ByteString
defaultValue Int = "0"
defaultValue Float = "0.0"
defaultValue Mat4 = "mat4(1.0)"
defaultValue Vec3 = "vec3(0.0, 0.0, 0.0)"
defaultValue Vec2 = "vec2(0.0, 0.0)"
defaultValue UInt = "0"
defaultValue Vec4 = "vec4(0.0, 0.0, 0.0, 0.0)"
defaultValue Sampler2D =
    error $ "ShaderM.defaultValue: Sampler2D does" ++
            "not have a default value."

-------------
-- Classes --
-------------

class WritableQS (a :: Symbol)
instance WritableQS "out"
instance WritableQS "none"

class ReadableQS (a :: Symbol)
instance ReadableQS "in"
instance ReadableQS "uniform"
instance ReadableQS "none"

class WritableQ q
instance WritableQS q => WritableQ (Value q t)
instance WritableQS q => WritableQ (Array l q t)
instance WritableQ (Expression t)

class ReadableQ q
instance ReadableQS q => ReadableQ (Value q t)
instance ReadableQS q => ReadableQ (Array l q t)
instance ReadableQ (Expression t)
instance ReadableQ Arg
instance ReadableQ B.ByteString
instance ReadableQ Float
instance ReadableQ Double
instance ReadableQ Int
instance ReadableQ Integer
instance ReadableQ Bool

class LayoutQS (a :: Symbol)
instance LayoutQS "in"
instance LayoutQS "uniform"
instance LayoutQS "out"

class LayoutQ q
instance LayoutQS q => LayoutQ (Value q t)

class HasBString a where
    getBString :: a -> B.ByteString
instance HasBString (Value q t) where
    getBString (Value name _ _) = name
instance HasBString (Expression t) where
    getBString (Expression str _) = str
instance HasBString Arg where
    getBString (Arg a) = getBString a
instance HasBString B.ByteString where
    getBString = id
instance HasBString Float where
    getBString = fromString . show
instance HasBString Double where
    getBString = fromString . show
instance HasBString Int where
    getBString = fromString . show
instance HasBString Integer where
    getBString = fromString . show
instance HasBString Bool where
    getBString True = "true"
    getBString False = "false"

-- = Swizzling

data Index (len :: Nat) (maxI :: Nat) where
    X :: Index 1 1
    Y :: Index 1 2
    Z :: Index 1 3
    W :: Index 1 4
    Linked :: Index len1 max1 -> Index len2 max2 ->
              Index (len1 + len2) (If (max1 <=? max2) max2 max1)

(.&) :: Index len1 max1 -> Index len2 max2 ->
        Index (len1 + len2) (If (max1 <=? max2) max2 max1)
(.&) = Linked

type family If (condition :: Bool) (yes :: Nat) (no :: Nat) :: Nat where
    If True yes no = yes
    If False yes no = no

instance BShow (Index len s) where
    bshow X = "x"
    bshow Y = "y"
    bshow Z = "z"
    bshow W = "w"
    bshow (Linked list1 list2) = bshow list1 `B.append` bshow list2

class Swizzle (glType :: Symbol) index (result :: Symbol) where
    (.@) :: (HasBString a, ReadableQ a, TypeOf a ~ glType) =>
            a -> index -> Expression result
    infixl 8 .@
instance (len ~ 1, maxI <= 2) => Swizzle "vec2" (Index len maxI) "float" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 1, maxI <= 3) => Swizzle "vec3" (Index len maxI) "float" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 1, maxI <= 4) => Swizzle "vec4" (Index len maxI) "float" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 2, maxI <= 2) => Swizzle "vec2" (Index len maxI) "vec2" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 3, maxI <= 3) => Swizzle "vec3" (Index len maxI) "vec3" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 4, maxI <= 4) => Swizzle "vec4" (Index len maxI) "vec4" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 2, maxI <= 3) => Swizzle "vec3" (Index len maxI) "vec2" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 2, maxI <= 4) => Swizzle "vec4" (Index len maxI) "vec2" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 3, maxI <= 2) => Swizzle "vec2" (Index len maxI) "vec3" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 3, maxI <= 4) => Swizzle "vec4" (Index len maxI) "vec3" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 4, maxI <= 2) => Swizzle "vec2" (Index len maxI) "vec4" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy
instance (len ~ 4, maxI <= 3) => Swizzle "vec3" (Index len maxI) "vec4" where
    (.@) value index =
        Expression ("(" `B.append` getBString value `B.append` ")." `B.append` bshow index) SProxy

--------------------
-- Array indexing --
--------------------

(.!) :: ReadableQS q => Array l q t -> Integer -> Expression t
(.!) (Array name _ _ _) i =
    Expression (name `B.append` "[" `B.append` (fromString $ show i) `B.append` "]") SProxy

---------------------------
-- Classes and instances --
---------------------------

class NumT (t :: Symbol)

instance NumT "int"
instance NumT "uint"
instance NumT "float"
instance NumT "vec4"
instance NumT "vec3"
instance NumT "vec2"
instance NumT "mat4"

class ScalarT (t :: Symbol)

instance ScalarT "int"
instance ScalarT "uint"
instance ScalarT "float"

class VecT (t :: Symbol)

instance VecT "vec2"
instance VecT "vec3"
instance VecT "vec4"

--------------
-- Families --
--------------

-- = TypeOf type family.

type family TypeOf a :: Symbol
type instance TypeOf (Value q t) = t
type instance TypeOf (Expression t) = t
type instance TypeOf (Array l q t) = t
type instance TypeOf Float = "float"
type instance TypeOf Double = "float"
type instance TypeOf Int = "int"
type instance TypeOf Integer = "int"

-- = QualifierOf type family.

type family QualifierOf a :: Symbol
type instance QualifierOf (Value q t) = q
type instance QualifierOf (Expression t) = "none"
type instance QualifierOf (Array l q t) = q

-- = Math type family.

type family Math (a :: Symbol) (b :: Symbol) :: Symbol

type instance Math a a = a

-- primitives
type instance Math "float" "int" = "float"
type instance Math "int" "float" = "float"
type instance Math "float" "uint" = "float"
type instance Math "uint" "float" = "float"
type instance Math "int" "uint" = "int"
type instance Math "uint" "int" = "int"

-- scalar + mat4 = mat4 (???)
type instance Math "int" "mat4" = "mat4"
type instance Math "float" "mat4" = "mat4"
type instance Math "uint" "mat4" = "mat4"
type instance Math "mat4" "int" = "mat4"
type instance Math "mat4" "float" = "mat4"
type instance Math "mat4" "uint" = "mat4"

-- vec + scalar = vec (???)
type instance Math "vec4" "float" = "vec4"
type instance Math "vec4" "uint" = "vec4"
type instance Math "vec4" "int" = "vec4"
type instance Math "float" "vec4" = "vec4"
type instance Math "uint" "vec4" = "vec4"
type instance Math "int" "vec4" = "vec4"
type instance Math "vec3" "float" = "vec3"
type instance Math "vec3" "uint" = "vec3"
type instance Math "vec3" "int" = "vec3"
type instance Math "float" "vec3" = "vec3"
type instance Math "uint" "vec3" = "vec3"
type instance Math "int" "vec3" = "vec3"
type instance Math "vec2" "float" = "vec2"
type instance Math "vec2" "uint" = "vec2"
type instance Math "vec2" "int" = "vec2"
type instance Math "float" "vec2" = "vec2"
type instance Math "uint" "vec2" = "vec2"
type instance Math "int" "vec2" = "vec2"

-- mat4 + vec = vec (???)
type instance Math "mat4" "vec4" = "vec4"
type instance Math "mat4" "vec3" = "vec3"
type instance Math "mat4" "vec2" = "vec2"
type instance Math "vec4" "mat4" = "vec4"
type instance Math "vec3" "mat4" = "vec3"
type instance Math "vec2" "mat4" = "vec2"

------------------
-- ShaderM Codegen --
------------------

programBString :: [GLSLUnit] -> B.ByteString
programBString xs =
    let (top, bottom) = filterTop xs
    in B.concat (map bshow top) `B.append`
       "\nvoid main(){\n" `B.append`
       B.concat (map bshow bottom) `B.append`
       "}"

-- | Filter declarations that appear at
--   the top of the file.
filterTop :: [GLSLUnit] -> ([GLSLUnit], [GLSLUnit])
filterTop (v@(Version{}) : xs) =
    let (top, bottom) = filterTop xs
    in (v : top, bottom)
filterTop (u@(Decl _ Uniform _ _) : xs) =
    let (top, bottom) = filterTop xs
    in (u : top, bottom)
filterTop (i@(Decl _ In _ _) : xs) =
    let (top, bottom) = filterTop xs
    in (i : top, bottom)
filterTop (o@(Decl _ Out _ _) : xs) =
    let (top, bottom) = filterTop xs
    in (o : top, bottom)
filterTop (x : xs) =
    let (top, bottom) = filterTop xs
    in (top, x : bottom)
filterTop [] = ([], [])

-------------
-- Testing --
-------------

testShow :: IO ()
testShow = C.putStrLn $ programBString testProg

testProg :: [GLSLUnit]
testProg = execShaderM simpleProgram

testLog :: GLSLInfo t
testLog = evalShaderM simpleProgram

simpleProgram :: ShaderM GL.VertexShader t ()
simpleProgram = do
    version "430 core"

    -- In variables.
    position <- layoutIn ["location=0"] vec3 ("position", const [])
    normal <- inn vec3 ("normal", const [])
    texCoord <- inn vec2 ("texCoord", const [])
    color <- inn vec3 ("color", const [])
    textureId <- inn float ("textureId", const [])

    -- Uniform variables.
    -- projectionMatrix <- uniform mat4 "projectionMatrix"
    viewMatrix <- uniform mat4 ("viewMatrix", const identity)
    modelMatrix <- uniform mat4 ("modelMatrix", const identity)
    mvpMatrix <- uniform mat4 ("mvpMatrix", const identity)

    uniformArray sampler2D "textures" (NProxy :: NatProxy 2)
        [const $ Sampler2DInfo undefined undefined]

    -- Out variables.
    positionCS <- out vec3 "positionCS"
    positionMS <- out vec3 "positionMS"
    normalCS <- out vec4 "normalCS"
    fragColor <- out vec3 "fragColor"
    textureCoord <- out vec2 "textureCoord"
    texId <- out int "texId"
    fogFactor <- out float "fogFactor"

    -- Pass frag color.
    fragColor #= color

    -- Create normal matrix.
    let normalMatrixE = transpose . inverse $ viewMatrix .* modelMatrix
    normalMatrix <- none mat4 "normalMatrix" $= normalMatrixE

    -- Pass the normal in camera space.
    let normalVec4 = "vec4" .$ [pack normal, pack (fltd 0.0)] :: Expression "vec4"
    normalCS #= normalMatrix .* normalVec4

    -- Pass model space position.
    positionMS #= position

    -- Pass position in camera space.
    let positionVec4 = "vec4" .$ [pack position, pack (fltd 1.0)] :: Expression "vec4"
        positionCS4 = viewMatrix .* modelMatrix .* positionVec4
    positionCS #= positionCS4 .@ X .& Y .& Z

    -- Pass texture coord.
    textureCoord #= texCoord
    -- Pass texture id.
    texId #= "int" <. textureId

    -- Pass position in clip space to gl_Position.
    glPosition #= mvpMatrix .* positionVec4

    -- Fog coord is the length of gl_Position.
    fogCoord <- none float "fogCoord" $= vlength glPosition

    fogDensity <- none float "fogDensity" $= fltd 0.03
    log2 <- none float "log2" $= fltd 1.442695

    fogFactor #= "exp2" <. 
        (fogDensity .* fogDensity .* intd (-1) .*
         fogCoord .* fogCoord .* log2)

    fogFactor #= clamp (ref float "fogFactor") (fltd 0.0) (fltd 1.0)

----------------
-- Assignment --
----------------

(#=) :: (HasBString a, HasBString b,
         WritableQ a, ReadableQ b,
         TypeOf a ~ TypeOf b) =>
    a -> b -> ShaderM s t ()
(#=) to from =
    ltell $ AssignStatement (getBString to) (getBString from)
infixr 1 #=

($=) :: (HasBString a, HasBString b,
         WritableQ a, ReadableQ b,
         TypeOf a ~ TypeOf b) =>
    ShaderM s t a -> b -> ShaderM s t a
($=) to from = do
    toVal <- to
    toVal #= from
    return toVal
infixr 1 $=

------------------------
-- Numeric operations --
------------------------

(.+) :: (HasBString a, HasBString b,
         ReadableQ a, ReadableQ b) =>
    a -> b -> Expression (Math (TypeOf a) (TypeOf b))
(.+) left right =
    Expression (paren (getBString left) `B.append` " + " `B.append` paren (getBString right))
                SProxy
infixl 6 .+

(.-) :: (HasBString a, HasBString b,
         ReadableQ a, ReadableQ b) =>
    a -> b -> Expression (Math (TypeOf a) (TypeOf b))
(.-) left right =
    Expression (paren (getBString left) `B.append` " - " `B.append` paren (getBString right))
                SProxy
infixl 6 .-

(.*) :: (HasBString a, HasBString b,
         ReadableQ a, ReadableQ b) =>
    a -> b -> Expression (Math (TypeOf a) (TypeOf b))
(.*) left right =
    Expression (paren (getBString left) `B.append` " * " `B.append` paren (getBString right))
                SProxy
infixl 7 .*

(./) :: (HasBString a, HasBString b,
         ReadableQ a, ReadableQ b) =>
    a -> b -> Expression (Math (TypeOf a) (TypeOf b))
(./) left right =
    Expression (paren (getBString left) `B.append` " / " `B.append` paren (getBString right))
                SProxy
infixl 7 ./

--------------------
-- ShaderM Built-ins --
--------------------

clamp :: (HasBString value, ReadableQ value, NumT (TypeOf value),
          HasBString bottom, ReadableQ bottom, NumT (TypeOf bottom),
          HasBString top, ReadableQ top, NumT (TypeOf top),
          TypeOf value ~ TypeOf bottom,
          TypeOf value ~ TypeOf top) =>
    value -> bottom -> top -> Expression (TypeOf value)
clamp value bottom top =
    Expression ("clamp(" `B.append` getBString value `B.append` "," `B.append`
                            getBString bottom `B.append` "," `B.append`
                            getBString top `B.append` ")") SProxy

transpose :: (HasBString mat, ReadableQ mat,
              TypeOf mat ~ "mat4") =>
    mat -> Expression "mat4"
transpose matrix =
    Expression ("transpose(" `B.append` getBString matrix `B.append` ")") SProxy

inverse :: (HasBString mat, ReadableQ mat,
            TypeOf mat ~ "mat4") =>
    mat -> Expression "mat4"
inverse matrix =
    Expression ("inverse(" `B.append` getBString matrix `B.append` ")") SProxy

vlength :: (HasBString vec, ReadableQ vec,
            VecT (TypeOf vec)) =>
    vec -> Expression "float"
vlength vec =
    Expression ("length(" `B.append` getBString vec `B.append` ")") SProxy


normalize :: (HasBString vec, ReadableQ vec,
              VecT (TypeOf vec)) =>
    vec -> Expression "float"
normalize vec =
    Expression ("normalize(" `B.append` getBString vec `B.append` ")") SProxy

reflect :: (HasBString vec, ReadableQ vec,
            VecT (TypeOf vec)) =>
    vec -> vec -> Expression "float"
reflect veca vecb =
    Expression ("reflect(" `B.append` getBString veca `B.append` ", " `B.append` getBString vecb `B.append` ")")
               SProxy

glPosition :: Value "none" "vec4"
glPosition = builtIn vec4 "gl_Position"

--------------------------
-- Function application --
--------------------------

(.$) :: (HasBString a,
         ReadableQ a) =>
    B.ByteString -> [a] -> Expression b
(.$) = apply
infixr 3 .$

(<.) :: (HasBString a,
         ReadableQ a) =>
    B.ByteString -> a -> Expression b
(<.) func x = apply func [x]
infixr 3 <.

apply :: (HasBString a,
          ReadableQ a) =>
    B.ByteString -> [a] -> Expression b
apply func args = Expression
    (func `B.append` paren (B.intercalate ", " $ map getBString args))
    SProxy

--------------------------
-- Variable declaration --
--------------------------

{-
decl :: (KnownSymbol q, KnownSymbol t) =>
    SymbolProxy q -> SymbolProxy t -> B.ByteString ->
    ShaderM gt (Value q t)
decl qualifier glType name = do
    ltell $ Decl (Layout []) (qualifierSymbol qualifier) (typeSymbol glType) name
    return $ Value name qualifier glType

uniform :: (KnownSymbol t, GPU t) =>
    SymbolProxy t -> B.ByteString -> (gt -> CPU t) -> ShaderM gt (Value "uniform" t)
uniform glType name value = do
    logUniform glType value name
    decl (SProxy :: SymbolProxy "uniform") glType name

out :: (KnownSymbol t, GPU t) =>
    SymbolProxy t -> B.ByteString -> ShaderM gt (Value "out" t)
out glType name = do
    logOut glType name
    decl (SProxy :: SymbolProxy "out") glType name

inn :: (KnownSymbol t, GPU t) =>
    SymbolProxy t -> B.ByteString -> (gt -> [CPU t]) -> ShaderM gt (Value "in" t)
inn glType name value = do
    logIn glType value name
    decl (SProxy :: SymbolProxy "in") glType name

none :: KnownSymbol t => SymbolProxy t -> B.ByteString -> ShaderM gt (Value "none" t)
none = decl (SProxy :: SymbolProxy "none")
-}

----------------------
-- Declaring Arrays --
----------------------

declArray :: (KnownNat l, KnownSymbol q, KnownSymbol t) =>
    [B.ByteString] -> NatProxy l -> SymbolProxy q -> SymbolProxy t -> B.ByteString ->
    ShaderM s gt (Array l q t)
declArray layouts len qualifier glType name = do
    let fullName = name `B.append` "[" `B.append` (fromString . show $ natVal len) `B.append` "]"
    ltell $ Decl (Layout layouts) (qualifierSymbol qualifier) (typeSymbol glType) fullName
    return $ Array name len qualifier glType

layoutUniformArray :: (KnownNat l, KnownSymbol t, GPU t) =>
    [B.ByteString] ->
    SymbolProxy t -> B.ByteString -> NatProxy l -> [gt -> CPU t] ->
    ShaderM s gt (Array l "uniform" t)
layoutUniformArray layouts glType name len values = do
    logUniformArray glType values name
    declArray layouts len (SProxy :: SymbolProxy "uniform") glType name

uniformArray :: (KnownNat l, KnownSymbol t, GPU t) =>
    SymbolProxy t -> B.ByteString -> NatProxy l -> [gt -> CPU t] -> ShaderM s gt (Array l "uniform" t)
uniformArray glType name len values = do
    logUniformArray glType values name
    declArray [] len (SProxy :: SymbolProxy "uniform") glType name

logUniformArray :: (KnownSymbol t, GPU t) =>
    SymbolProxy t -> [gt -> CPU t] -> B.ByteString -> ShaderM s gt ()
logUniformArray glType xs name =
    loop (0::Int) xs
  where
    loop i (valueFunc:otherFuncs) = do
        let fullName = name `B.append` "[" `B.append`
                (fromString $ show i) `B.append` "]"
        logUniform glType valueFunc fullName
        loop (i+1) otherFuncs
    loop _ [] = return ()

------------------------
-- Const Declarations --
------------------------

builtIn :: KnownSymbol t => SymbolProxy t -> B.ByteString -> Value "none" t
builtIn glType name = Value name nonep glType

ref :: KnownSymbol t => SymbolProxy t -> B.ByteString -> Value "none" t
ref = builtIn

constant :: KnownSymbol t => SymbolProxy t -> B.ByteString -> Expression t
constant glType name = Expression name glType

constNum :: (KnownSymbol t, Num a, Show a) => SymbolProxy t -> a -> Expression t
constNum glType value = Expression (fromString $ show value) glType

constInt :: Int -> Expression "int"
constInt = constant (SProxy :: SymbolProxy "int") . fromString . show

constFloat :: Float -> Expression "float"
constFloat = constant (SProxy :: SymbolProxy "float") . fromString . show

------------
-- Layout --
------------

{-
layoutDecl :: (KnownSymbol q, KnownSymbol t) =>
    [B.ByteString] ->
    SymbolProxy q -> SymbolProxy t -> B.ByteString ->
    ShaderM gt (Value q t)
layoutDecl layouts qualifier glType name = do
    ltell $ Decl (Layout layouts) (qualifierSymbol qualifier) (typeSymbol glType) name
    return $ Value name qualifier glType

layoutUniform :: (KnownSymbol t, GPU t) =>
    [B.ByteString] ->
    SymbolProxy t -> B.ByteString -> (gt -> CPU t) -> ShaderM gt (Value "uniform" t)
layoutUniform layouts glType name value = do
    logUniform glType value name
    layoutDecl layouts (SProxy :: SymbolProxy "uniform") glType name

layoutOut :: (KnownSymbol t, GPU t) =>
    [B.ByteString] ->
    SymbolProxy t -> B.ByteString -> ShaderM gt (Value "out" t)
layoutOut layouts glType name = do
    logOut glType name
    layoutDecl layouts (SProxy :: SymbolProxy "out") glType name

layoutIn :: (KnownSymbol t, GPU t) =>
    [B.ByteString] ->
    SymbolProxy t -> B.ByteString -> (gt -> [CPU t]) -> ShaderM gt (Value "in" t)
layoutIn layouts glType name value = do
    logIn glType value name
    layoutDecl layouts (SProxy :: SymbolProxy "in") glType name
-}

-----------------
-- Other utils --
-----------------

version :: B.ByteString -> ShaderM s t ()
version = ltell . Version

paren :: B.ByteString -> B.ByteString
paren s = "(" `B.append` s `B.append` ")"

fltd :: Float -> Float
fltd = id

intd :: Int -> Int
intd = id

ltell :: GLSLUnit -> ShaderM s t ()
ltell s = tell ([s], mempty)

rtell :: GLSLInfo t -> ShaderM s t ()
rtell s = tell ([], s)
