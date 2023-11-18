{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeFamilies  #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CryptoMonad where

import Data.Kind (Type)

import Data.Functor.Identity (Identity)

import qualified Control.Concurrent.STM.TChan as STM
import qualified Control.Concurrent.Async as A
import Control.Monad (msum)
import qualified Control.Monad.STM as STM --also supplies instance MonadPlus STM

-- free monads

import Control.Monad (ap)
import Data.Void (Void)
data Free f a =
    Pure a
    | Free (f (Free f a))
    deriving Functor

instance Functor f => Applicative (Free f) where
    pure = Pure
    (<*>) = ap

instance Functor f => Monad (Free f) where
    Pure a >>= f = f a
    Free g >>= f = Free $ fmap (>>= f) g

liftF :: Functor f => f a -> Free f a
liftF f = Free $ pure <$> f

-- heterogenous lists

data HeteroList f (types :: [Type]) where
    HNil :: HeteroList f '[]
    HCons :: f t -> HeteroList f ts -> HeteroList f (t : ts)

data InList x xs where
    Here :: InList x (x : xs)
    There :: InList x xs -> InList x (y : xs)

heteroListGet :: HeteroList f types -> InList x types -> f x
heteroListGet (HCons x xs) Here = x
heteroListGet (HCons x xs) (There t) = heteroListGet xs t

homogenize
  :: (forall x. InList x types -> f x -> a)
  -> HeteroList f types
  -> [a]
homogenize _ HNil = []
homogenize g (HCons x xs) = g Here x : homogenize (g . There) xs

-- heteroTraverse :: (InList x types -> fInList x types -> x -> f x) -> HeteroList Identity types -> HeteroList f types
-- heteroTraverse _ HNil = HNil
-- heteroTraverse g (HCons x xs) =

data SomeIndex xs where
    SomeIndex :: InList x xs -> SomeIndex xs

data SomeMessage xs where
  SomeMessage :: InList x xs -> x -> SomeMessage xs

-- domain-specific definitions

data CryptoActions (send :: [Type]) (recv :: [Type]) a where
    ReceiveAnyAction :: (SomeMessage recv -> a) -> CryptoActions send recv a
    ReceiveAction :: InList b recv -> (b -> a) -> CryptoActions send recv a
    SendAction :: InList b send -> b -> a -> CryptoActions send recv a

instance Functor (CryptoActions send recv) where
    fmap f (ReceiveAnyAction g) = ReceiveAnyAction (f . g)
    fmap f (ReceiveAction i g) = ReceiveAction i (f . g)
    fmap f (SendAction i b a) = SendAction i b $ f a

-- wrappers

type CryptoMonad send recv = Free (CryptoActions send recv)

recvAny :: CryptoMonad send recv (SomeMessage recv)
recvAny = liftF (ReceiveAnyAction id)

recv :: InList b recv -> CryptoMonad send recv b
recv i = liftF (ReceiveAction i id)

send :: InList b send -> b -> CryptoMonad send recv ()
send i b = liftF (SendAction i b ())

pattern Alice :: () => (xs ~ (x : xs1)) => InList x xs
pattern Alice = Here
pattern Bob :: () => (xs ~ (y : xs1), xs1 ~ (x : xs2)) => InList x xs
pattern Bob = There Here
pattern Charlie :: () => (xs ~ (y1 : xs1), xs1 ~ (y2 : xs2), xs2 ~ (x : xs3)) => InList x xs
pattern Charlie = There (There Here)

-- usage

data BobAlgo = BobAlgo (CryptoMonad [Int, Void, BobAlgo] [Bool, Void, String] Bool)

-- | Keep running an operation until it becomes a 'Just', then return the value
--   inside the 'Just' as the result of the overall loop.
untilJustM :: Monad m => m (Maybe a) -> m a
untilJustM act = do
    res <- act
    case res of
        Just r  -> pure r
        Nothing -> untilJustM act

alg1 :: CryptoMonad [Int, Void, BobAlgo] [Bool, Void, String] Bool
alg1 = do str <- recv Charlie
          send Alice $ length str
          send Charlie $ BobAlgo alg1
          recv Alice

-- zipped version for when there's exactly one interface per person

type family Fst p where
  Fst (a, b) = a

type family Snd p where
  Snd (a, b) = b

type family Map (f :: Type -> Type) xs where
  Map f '[] = '[]
  Map f (x : xs) = f x : Map f xs

type CryptoMonad' people = CryptoMonad (Map Fst people) (Map Snd people)

alg1' :: CryptoMonad' [(Int, Bool), (Void, Void), (BobAlgo, String)] Bool
alg1' = alg1

-- This is not a good idea. I must add an extra constructor for CryptoActions
-- if I want to hide parties in a clean way. The implementation here is buggy.
hidingRecvParty :: CryptoMonad send recv a -> CryptoMonad send (x:recv) a
hidingRecvParty (Pure x) = Pure x
hidingRecvParty (Free (ReceiveAnyAction f))
  = Free
  $ ReceiveAnyAction
  -- BUG is here: we throw an error if we get message from a party we don't
  -- expect a message from
  $ \(SomeMessage (There i) x) -> hidingRecvParty $ f (SomeMessage i x)
hidingRecvParty (Free (ReceiveAction i f))
  = Free
  $ ReceiveAction (There i) (hidingRecvParty . f)
hidingRecvParty (Free (SendAction i m a))
  = Free
  $ SendAction i m
  $ hidingRecvParty a

-- Interpretation of the CryptoMonad

run :: HeteroList STM.TChan send
    -> HeteroList STM.TChan receive
    -> CryptoMonad send receive a
    -> IO a
run s r = \case
  Pure x -> pure x
  Free (ReceiveAnyAction f) -> do
    let chans = homogenize (\i c -> SomeMessage i <$> STM.readTChan c) r
    m <- STM.atomically $ msum chans
    run s r $ f m
  Free (ReceiveAction i f) -> do
    m <- STM.atomically $ STM.readTChan
                        $ heteroListGet r i
    run s r $ f m
  Free (SendAction i m a) -> do
    STM.atomically $ STM.writeTChan (heteroListGet s i) m
    run s r a

-- The parties available will go in order:
--
--  * Environment
--  * Adversary
--  * F₁
--  * F₂
--  * …
--  * P₁
--  * P₂
--  * …

-- signatureFunctionality :: CryptoMonad' parties a

test :: String -> String -> IO (Int, String)
test a b = do
    aToBChan <- STM.newTChanIO
    bToAChan <- STM.newTChanIO
    let aToB = HCons aToBChan HNil
    let bToA = HCons bToAChan HNil
    aliceA <- A.async $ run aToB bToA alice
    bobA <- A.async $ run bToA aToB bob
    A.waitBoth aliceA bobA
  where
    alice :: CryptoMonad' '[(String, Int)] Int
    alice = do
      send Here a
      recvAny >>= \case
        SomeMessage Here x -> pure x
        SomeMessage contra _ -> case contra of
    bob :: CryptoMonad' '[(Int, String)] String
    bob = do
      s <- recv Here
      send Here $ length s
      pure $ "got from Alice " ++ show s ++ " while my input is " ++ show b
