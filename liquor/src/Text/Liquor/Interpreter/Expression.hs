{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}

module Text.Liquor.Interpreter.Expression where

import Prelude hiding (Bool, String)
import qualified Prelude
import Control.Lens ((^?))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Lens as Lens
import qualified Data.Convertible as Convertible
import qualified Data.List.NonEmpty as NonEmptyList
import qualified Data.Scientific as Scientific
import Data.Semigroup ((<>))
import qualified Data.Text as Text
import qualified Data.Vector as Vector

import Text.Liquor.Common
import Text.Liquor.Interpreter.Common

newtype Expression e = Inject (e (Expression e))

foldExpression :: Functor e => (e a -> a) -> Expression e -> a
foldExpression e (Inject t) = e (fmap (foldExpression e) t)

class Functor e => Evaluate e where
  evaluateAlgebra :: Context -> e (Result ValueData) -> Result ValueData

instance (Evaluate f, Evaluate g) => Evaluate (f :+: g) where
  evaluateAlgebra c (InjectLeft x) = evaluateAlgebra c x
  evaluateAlgebra c (InjectRight x) = evaluateAlgebra c x

evaluate :: Evaluate e => Context -> Expression e -> Result ValueData
evaluate c = foldExpression (evaluateAlgebra c)

inject :: g :<: f => g (Expression f) -> Expression f
inject = Inject . inj

type Shopify = Value :+: Variable :+: Less :+: LessEqual :+: Greater :+: GreaterEqual :+: Equal :+: NotEqual :+: And :+: Or :+: ArrayAt
type ShopifySuper e =
  ( Value :<: e, Variable :<: e
  , Less :<: e, LessEqual :<: e, Greater :<: e, GreaterEqual :<: e, Equal :<: e, NotEqual :<: e
  , And :<: e, Or :<: e
  , ArrayAt :<: e
  )

-- Value

data ValueData
  = Number !Scientific.Scientific
  | String !Text.Text
  | Bool !Prelude.Bool
  | Nil
  | Array !(Vector.Vector ValueData)
  deriving (Show, Eq)

newtype Value e = Value ValueData
  deriving Functor

instance Evaluate Value where
  evaluateAlgebra _ (Value v) = Right v

number :: Value :<: e => Scientific.Scientific -> Expression e
number = inject . Value . Number

string :: Value :<: e => Text.Text -> Expression e
string = inject . Value . String

bool :: Value :<: e => Prelude.Bool -> Expression e
bool = inject . Value . Bool

nil :: Value :<: e => Expression e
nil = inject $ Value Nil

array :: Value :<: e => Vector.Vector ValueData -> Expression e
array = inject . Value . Array

--- Bool

asBool :: ValueData -> Prelude.Bool
asBool (Bool v) = v
asBool Nil = False
asBool _ = True

--- Aeson.Value

instance Convertible.Convertible Aeson.Value ValueData where
  safeConvert v@(Aeson.Object _) = Convertible.convError "variable must be assigned with value" v
  safeConvert (Aeson.Array a) = Array <$> traverse Convertible.safeConvert a
  safeConvert (Aeson.String t) = Right $ String t
  safeConvert (Aeson.Number n) = Right $ Number n
  safeConvert (Aeson.Bool b) = Right $ Bool b
  safeConvert Aeson.Null = Right Nil

instance Convertible.Convertible ValueData Aeson.Value where
  safeConvert (Array a) = Aeson.Array <$> traverse Convertible.safeConvert a
  safeConvert (String t) = Right $ Aeson.String t
  safeConvert (Number n) = Right $ Aeson.Number n
  safeConvert (Bool b) = Right $ Aeson.Bool b
  safeConvert Nil = Right Aeson.Null

--- Render

render :: ValueData -> Text.Text
render (Number n) =
  case Scientific.floatingOrInteger n of
    Left f -> Text.pack $ show (f :: Double)
    Right i -> Text.pack $ show (i :: Integer)
render (String t) = t
render (Bool True) = "true"
render (Bool False) = "false"
render Nil = ""
render (Array a) = Text.pack $ show a

-- Variable

newtype Variable e = Variable VariablePath
  deriving Functor

instance Evaluate Variable where
  evaluateAlgebra c (Variable p) = evaluateVariable c p

type VariablePath = NonEmptyList.NonEmpty VariableName

data VariableName = ObjectKey Text.Text | ArrayKey Int
  deriving (Show, Eq)

variable :: Variable :<: e => VariablePath -> Expression e
variable = inject . Variable

evaluateVariable :: Context -> VariablePath -> Result ValueData
evaluateVariable c p
  = either Left (either (Left . Text.pack . Convertible.convErrorMessage) Right . Convertible.safeConvert)
  $ maybe (Left $ "variable not found: " <> pp p) Right
  $ Aeson.Object c ^? build p
  where
    build :: Applicative f => VariablePath -> ((Aeson.Value -> f Aeson.Value) -> Aeson.Value -> f Aeson.Value)
    build xs = foldl1 (.) (matchKey <$> xs)
      where
        matchKey (ObjectKey i) = Lens.key i
        matchKey (ArrayKey i)  = Lens.nth i
    pp :: VariablePath -> Text.Text
    pp = foldr go ""
      where
        go (ObjectKey i) "" = i
        go (ObjectKey i) acc = acc <> "." <> i
        go (ArrayKey i) acc = acc <> "[" <> Text.pack (show i) <> "]"

-- Binary Operator

--- Less

data Less e = Less e e
  deriving Functor

instance Evaluate Less where
  evaluateAlgebra _ (Less (Right (Bool x)) (Right (Bool y))) = Right $ Bool $ x < y
  evaluateAlgebra _ (Less (Right (Number x)) (Right (Number y))) = Right $ Bool $ x < y
  evaluateAlgebra _ (Less (Right (String x)) (Right (String y))) = Right $ Bool $ x < y
  evaluateAlgebra _ (Less r@(Left _) _) = r
  evaluateAlgebra _ (Less _ r@(Left _)) = r
  evaluateAlgebra _ (Less _ _) = Left "invalid parameter for less"

(.<.) :: Less :<: e => Expression e -> Expression e -> Expression e
x .<. y = inject (Less x y)
infix 4 .<.

--- Less or Equal

data LessEqual e = LessEqual e e
  deriving Functor

instance Evaluate LessEqual where
  evaluateAlgebra _ (LessEqual (Right (Bool x)) (Right (Bool y))) = Right $ Bool $ x <= y
  evaluateAlgebra _ (LessEqual (Right (Number x)) (Right (Number y))) = Right $ Bool $ x <= y
  evaluateAlgebra _ (LessEqual (Right (String x)) (Right (String y))) = Right $ Bool $ x <= y
  evaluateAlgebra _ (LessEqual r@(Left _) _) = r
  evaluateAlgebra _ (LessEqual _ r@(Left _)) = r
  evaluateAlgebra _ (LessEqual _ _) = Left "invalid parameter for less equal"

(.<=.) :: LessEqual :<: e => Expression e -> Expression e -> Expression e
x .<=. y = inject (LessEqual x y)
infix 4 .<=.

--- Grater

data Greater e = Greater e e
  deriving Functor

instance Evaluate Greater where
  evaluateAlgebra _ (Greater (Right (Bool x)) (Right (Bool y))) = Right $ Bool $ x > y
  evaluateAlgebra _ (Greater (Right (Number x)) (Right (Number y))) = Right $ Bool $ x > y
  evaluateAlgebra _ (Greater (Right (String x)) (Right (String y))) = Right $ Bool $ x > y
  evaluateAlgebra _ (Greater r@(Left _) _) = r
  evaluateAlgebra _ (Greater _ r@(Left _)) = r
  evaluateAlgebra _ (Greater _ _) = Left "invalid parameter for grater"

(.>.) :: Greater :<: e => Expression e -> Expression e -> Expression e
x .>. y = inject (Greater x y)
infix 4 .>.

--- Grater or Equal

data GreaterEqual e = GreaterEqual e e
  deriving Functor

instance Evaluate GreaterEqual where
  evaluateAlgebra _ (GreaterEqual (Right (Bool x)) (Right (Bool y))) = Right $ Bool $ x >= y
  evaluateAlgebra _ (GreaterEqual (Right (Number x)) (Right (Number y))) = Right $ Bool $ x >= y
  evaluateAlgebra _ (GreaterEqual (Right (String x)) (Right (String y))) = Right $ Bool $ x >= y
  evaluateAlgebra _ (GreaterEqual r@(Left _) _) = r
  evaluateAlgebra _ (GreaterEqual _ r@(Left _)) = r
  evaluateAlgebra _ (GreaterEqual _ _) = Left "invalid parameter for grater equal"

(.>=.) :: GreaterEqual :<: e => Expression e -> Expression e -> Expression e
x .>=. y = inject (GreaterEqual x y)
infix 4 .>=.

--- Equal

data Equal e = Equal e e
  deriving Functor

instance Evaluate Equal where
  evaluateAlgebra _ (Equal (Right (Bool x)) (Right (Bool y))) = Right $ Bool $ x == y
  evaluateAlgebra _ (Equal (Right (Number x)) (Right (Number y))) = Right $ Bool $ x == y
  evaluateAlgebra _ (Equal (Right (String x)) (Right (String y))) = Right $ Bool $ x == y
  evaluateAlgebra _ (Equal r@(Left _) _) = r
  evaluateAlgebra _ (Equal _ r@(Left _)) = r
  evaluateAlgebra _ (Equal _ _) = Left "invalid parameter for equal"

(.==.) :: Equal :<: e => Expression e -> Expression e -> Expression e
x .==. y = inject (Equal x y)
infix 4 .==.

--- Not Equal

data NotEqual e = NotEqual e e
  deriving Functor

instance Evaluate NotEqual where
  evaluateAlgebra _ (NotEqual (Right (Bool x)) (Right (Bool y))) = Right $ Bool $ x /= y
  evaluateAlgebra _ (NotEqual (Right (Number x)) (Right (Number y))) = Right $ Bool $ x /= y
  evaluateAlgebra _ (NotEqual (Right (String x)) (Right (String y))) = Right $ Bool $ x /= y
  evaluateAlgebra _ (NotEqual r@(Left _) _) = r
  evaluateAlgebra _ (NotEqual _ r@(Left _)) = r
  evaluateAlgebra _ (NotEqual _ _) = Left "invalid parameter for not equal"

(./=.) :: NotEqual :<: e => Expression e -> Expression e -> Expression e
x ./=. y = inject (NotEqual x y)
infix 4 ./=.

--- And

data And e = And e e
  deriving Functor

instance Evaluate And where
  evaluateAlgebra _ (And (Right x) (Right y)) = Right $ Bool $ asBool x && asBool y
  evaluateAlgebra _ (And r@(Left _) _) = r
  evaluateAlgebra _ (And _ r@(Left _)) = r

(.&&.) :: And :<: e => Expression e -> Expression e -> Expression e
x .&&. y = inject (And x y)
infix 3 .&&.

--- Or

data Or e = Or e e
  deriving Functor

instance Evaluate Or where
  evaluateAlgebra _ (Or (Right x) (Right y)) = Right $ Bool $ asBool x && asBool y
  evaluateAlgebra _ (Or r@(Left _) _) = r
  evaluateAlgebra _ (Or _ r@(Left _)) = r

(.||.) :: Or :<: e => Expression e -> Expression e -> Expression e
x .||. y = inject (Or x y)
infix 2 .||.

-- Array

--- At

data ArrayAt e = ArrayAt e e
  deriving Functor

instance Evaluate ArrayAt where
  evaluateAlgebra _ (ArrayAt (Right (Array a)) (Right (Number i)))
    | Scientific.isInteger i = maybe (Left "index out of range") Right $ a Vector.!? round i
    | otherwise = Left "index must be integer"
  evaluateAlgebra _ (ArrayAt r@(Left _) _) = r
  evaluateAlgebra _ (ArrayAt _ r@(Left _)) = r
  evaluateAlgebra _ _ = Left "invalid parameter for array at"

at :: ArrayAt :<: e => Expression e -> Expression e -> Expression e
at x y = inject (ArrayAt x y)
infix 5 `at`
