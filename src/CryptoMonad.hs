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
{-# LANGUAGE ImpredicativeTypes #-}

module CryptoMonad where

import Data.Kind (Type)

import Data.Functor ((<&>))

import qualified Control.Concurrent.STM.TChan as STM
import qualified Control.Concurrent.Async as A
import Control.Monad (msum)
import Control.Arrow (second)
import qualified Control.Monad.STM as STM --also supplies instance MonadPlus STM

import Data.Type.Equality ((:~:)(Refl))

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

areInListEqual :: InList x xs -> InList y xs -> Maybe (x :~: y)
areInListEqual Here Here = Just Refl
areInListEqual (There a) (There b) = areInListEqual a b
areInListEqual _ _ = Nothing

heteroListGet :: HeteroList f types -> InList x types -> f x
heteroListGet (HCons x _) Here = x
heteroListGet (HCons _ xs) (There t) = heteroListGet xs t
heteroListGet HNil contra = case contra of

homogenize
  :: (forall x. InList x types -> f x -> a)
  -> HeteroList f types
  -> [a]
homogenize _ HNil = []
homogenize g (HCons x xs) = g Here x : homogenize (g . There) xs

data SomeIndex xs where
    SomeIndex :: InList x xs -> SomeIndex xs

data SomeMessage xs where
  SomeMessage :: InList x xs -> x -> SomeMessage xs

data SomeSndMessage xs where
  SomeSndMessage :: InList (x, y) xs -> y -> SomeSndMessage xs

data SomeFstMessage xs where
  SomeFstMessage :: InList (x, y) xs -> x -> SomeFstMessage xs

padMessageIndex :: SomeMessage ts -> SomeMessage (t : ts)
padMessageIndex (SomeMessage i' x') = SomeMessage (There i') x'

-- domain-specific definitions

data CryptoActions (l :: [Type]) a where
    RecvAction :: (SomeSndMessage l -> a) -> CryptoActions l a
    SendAction :: SomeFstMessage l -> a -> CryptoActions l a

instance Functor (CryptoActions l) where
    fmap f (RecvAction g) = RecvAction (f . g)
    fmap f (SendAction m a) = SendAction m $ f a

-- wrappers

type CryptoMonad l = Free (CryptoActions l)

recvAny :: CryptoMonad l (SomeSndMessage l)
recvAny = liftF (RecvAction id)

-- |Waits for message from this specific party. Until it arrives, collect all
-- the messages from all other parties.
recvCollecting :: InList (a, b) l -> CryptoMonad l ([SomeSndMessage l], b)
recvCollecting i = do
  m@(SomeSndMessage j x) <- recvAny
  case areInListEqual i j of
    Nothing -> do
      (ms, res) <- recvCollecting i
      pure (m : ms, res)
    Just Refl -> pure ([], x)

-- |Same as @recvCollecting@, but drops the messages from other parties.
recvDropping :: InList (a, b) l -> CryptoMonad l b
recvDropping i = snd <$> recvCollecting i

data HeteroListP2 f a (types :: [Type]) where
    HNilP2 :: HeteroListP2 f a '[]
    HConsP2 :: f t a -> HeteroListP2 f a ts -> HeteroListP2 f a (t : ts)

-- |Allows for cleaner code than pattern-matching over @SomeMessage recv@, or
-- pairwise comparisons using @areInListEqual@
repackMessage :: HeteroListP2 InList recv is -> SomeMessage recv -> Maybe (SomeMessage is)
repackMessage HNilP2 _ = Nothing
repackMessage (HConsP2 i is) m@(SomeMessage j x) = case areInListEqual i j of
    Just Refl -> Just $ SomeMessage Here x
    Nothing -> padMessageIndex <$> repackMessage is m

-- -- |Same as @recvDropping@, but takes a list of valid senders to get messages from
-- recvOneOfDropping :: HeteroListP2 InList l is -> CryptoMonad l (SomeMessage (MapSnd is))
-- recvOneOfDropping i = do
--   m <- recvAny
--   case repackMessage i m of
--     Nothing -> recvOneOfDropping i
--     Just m' -> pure m'

sendSomeMess :: SomeFstMessage l -> CryptoMonad l ()
sendSomeMess m = liftF (SendAction m ())

send :: InList (b, a) l -> b -> CryptoMonad l ()
send i b = sendSomeMess $ SomeFstMessage i b

-- usage

data BobAlgo = BobAlgo (CryptoMonad [(Int, Bool), (Void, Void), (BobAlgo, String)] Bool)

alg1 :: CryptoMonad [(Int, Bool), (Void, Void), (BobAlgo, String)] Bool
alg1 = do str <- recvDropping charlie
          send alice $ length str
          send charlie $ BobAlgo alg1
          recvDropping alice
  where
    alice = Here
    bob = There Here
    charlie = There (There Here)

-- zipped version for when there's exactly one interface per person

type family Fst p where
    Fst (a, b) = a

type family Snd p where
    Snd (a, b) = b

type family MapFst xs where
    MapFst '[] = '[]
    MapFst (p : xs) = Fst p : MapFst xs

type family MapSnd xs where
    MapSnd '[] = '[]
    MapSnd (p : xs) = Snd p : MapSnd xs

type family Swap p where
    Swap ((,) x y) = (,) y x

-- type CryptoMonad' people = CryptoMonad (MapFst people) (MapSnd people)

-- send' :: InList (a, b) l -> a -> CryptoMonad l ()
-- send' i m = send (inListFst i) m

-- heteroListP2mapSnd :: HeteroListP2 InList l is -> HeteroListP2 InList (MapSnd l) (MapSnd is)
-- heteroListP2mapSnd HNilP2 = HNilP2
-- heteroListP2mapSnd (HConsP2 x xs) = HConsP2 (inListSnd x) (heteroListP2mapSnd xs)

-- recvOneOfDropping' :: HeteroListP2 InList l is -> CryptoMonad l (SomeMessage is)
-- recvOneOfDropping' i = recvOneOfDropping $ inListSnd i

-- recvDropping' :: InList (a, b) l -> CryptoMonad l b
-- recvDropping' i = recvDropping $ inListSnd i

inListFst :: InList ((,) a b) l -> InList a (MapFst l)
inListFst Here = Here
inListFst (There x) = There $ inListFst x

inListSnd :: InList ((,) a b) l -> InList b (MapSnd l)
inListSnd Here = Here
inListSnd (There x) = There $ inListSnd x

alg1' :: CryptoMonad [(Int, Bool), (Void, Void), (BobAlgo, String)] Bool
alg1' = alg1

-- |Returns @Left (x, f)@ if the underlying monad has received message x
-- intended for the hidden party. The f returned is the remaining computation
-- tail. You can handle the x yourself and then continues executing the
-- remaining f if you wish to.
--
-- Returns @Right a@ if the simulated computation exited successfully (and all
-- arrived messages were ok) with result @a@.
hidingParty
  :: CryptoMonad l a
  -> CryptoMonad ((x, y):l) (Either (y, CryptoMonad l a) a)
hidingParty (Pure x) = Pure $ Right x
hidingParty y@(Free (RecvAction f))
  = Free
  $ RecvAction
  $ \case
    (SomeSndMessage Here x) -> Pure $ Left (x, y)
    (SomeSndMessage (There i) x) -> hidingParty $ f (SomeSndMessage i x)
hidingParty (Free (SendAction (SomeFstMessage i m) a))
  = Free
  $ SendAction (SomeFstMessage (There i) m)
  $ hidingParty a

-- Interpretation of the CryptoMonad

data TwoChans t where
  TwoChans :: STM.TChan a -> STM.TChan b -> TwoChans (a, b)

runSTM :: HeteroList TwoChans l
    -> CryptoMonad l a
    -> IO a
runSTM l = \case
  Pure x -> pure x
  Free (RecvAction f) -> do
    let chans = homogenize (\i (TwoChans _ r) -> SomeSndMessage i <$> STM.readTChan r) l
    m <- STM.atomically $ msum chans
    runSTM l $ f m
  Free (SendAction (SomeFstMessage i m) a) -> do
    STM.atomically $ do
      let (TwoChans s _) = heteroListGet l i
      STM.writeTChan s m
    runSTM l a

type VoidInterface = (Void, Void)
type AliceBobInterface = (String, Int)

-- aliceName = Here

alice :: (l ~ '[VoidInterface, AliceBobInterface])
      => InList AliceBobInterface l -> CryptoMonad l Int
alice bobName = do
  -- let bobRecv = inListSnd bobName
  send bobName "alice to bob string"
  recvDropping bobName

bob :: (l ~ '[Swap AliceBobInterface, VoidInterface])
    => InList (Swap AliceBobInterface) l -> CryptoMonad l String
bob aliceName = do
  s <- recvDropping aliceName
  send aliceName $ length s
  pure $ "got from Alice " ++ show s

test2STM :: IO (Int, String)
test2STM = do
    aToBChan <- STM.newTChanIO
    bToAChan <- STM.newTChanIO
    voidChan <- STM.newTChanIO
    let aliceCh = HCons (TwoChans voidChan voidChan) (HCons (TwoChans aToBChan bToAChan) HNil)
    let bobCh = HCons (TwoChans bToAChan aToBChan) (HCons (TwoChans voidChan voidChan) HNil)
    aliceA <- A.async $ runSTM aliceCh $ alice (There Here)
    bobA <- A.async $ runSTM bobCh $ bob Here
    A.waitBoth aliceA bobA

-- Single-threaded Cooperative Multitasking Interpretation of the Monad.
--
-- This is defined by the original UC paper

data Thread l a
  = ThDone a
  | ThRunning (SomeSndMessage l -> Free (CryptoActions l) a)

-- |Start a new thread and run it until it terminates or tries to recv. Collect
-- messages that it tries to send.
newThread :: CryptoMonad l a
          -> (Thread l a, [SomeFstMessage l])
newThread (Pure x) = (ThDone x, [])
newThread (Free (RecvAction a)) = (ThRunning a, [])
newThread (Free (SendAction m a)) = second (m:) $ newThread a

deliverThread :: SomeSndMessage l
              -> Thread l a
              -> (Thread l a, [SomeFstMessage l])
deliverThread _ t@(ThDone _) = (t, [])
deliverThread m (ThRunning a) = case a m of
  Pure x -> (ThDone x, [])
  a' -> newThread a'

-- runCoop2PC :: CryptoMonad [(Void, Void), (a, b)] c
--            -> CryptoMonad [(b, a), (Void, Void)] d
--            -> (Maybe c, Maybe d)
-- runCoop2PC p1 p2 = helper (t1, t2, map Left m1 ++ map Right m2)
--   where
--     returned (ThDone a) = Just a
--     returned (ThRunning _) = Nothing

--     (t1, m1) = newThread p1
--     (t2, m2) = newThread p2

--     helper :: (Thread [Void, a] [Void, b] c, Thread [b, Void] [a, Void] d, Either (SomeMessage )
--     helper (th1, th2, []) = (returned th1, returned th2)
--     helper (th1, th2, (m:ms)) = case m of
--       Left m -> _
--       Right _ -> undefined
