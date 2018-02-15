{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}

module Text.Liquoh.Interpreter where

import qualified Data.Aeson as Aeson
import qualified Data.Text as Text

data (f :+: g) e = InjectLeft (f e) | InjectRight (g e)
  deriving (Show, Functor)
infixr 8 :+:

class (Functor sub, Functor sup) => sub :<: sup where
  inj :: sub a -> sup a

instance {-# OVERLAPPABLE #-} (Functor f, Functor g, f ~ g) => f :<: g where
  inj = id

instance {-# OVERLAPPING #-} (Functor f, Functor g) => f :<: (f :+: g) where
  inj = InjectLeft

instance {-# OVERLAPPING #-} (Functor f, Functor g, Functor h, f :<: g) => f :<: (h :+: g) where
  inj = InjectRight . inj

type Result = Either Text.Text

type Context = Aeson.Value