module UCHS.Types
  ( module Data.HList
  , module Data.Void
  , module Data.Kind
  , SBool(..)
  , Or
  , Fst
  , Snd
  , Empty
  , IfThenElse
  )
where

import Data.Void (Void)

import Data.Kind (Type)
import Data.HList

-- |Singleton @Bool@ used to store the dependent value of Write Token
data SBool (a :: Bool) where
  STrue :: SBool True
  SFalse :: SBool False

type Or :: Bool -> Bool -> Bool
type family Or x y where
  Or True _ = True
  Or _ True = True
  Or _ _ = False

type Fst :: (Type, Type) -> Type
type family Fst p where
  Fst '(x, _) = x

type Snd :: (Type, Type) -> Type
type family Snd p where
  Snd '(_, y) = y

-- |Type-level if-then-else, we use it to choose constraints conditionally
type IfThenElse :: forall a. Bool -> a -> a -> a
type family IfThenElse c t f where
  IfThenElse True t _ = t
  IfThenElse False _ f = f

-- |Empty constraint
class Empty x
instance Empty x
