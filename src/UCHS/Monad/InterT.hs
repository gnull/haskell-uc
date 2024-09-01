{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ScopedTypeVariables #-}

module UCHS.Monad.InterT (
  -- * Interactive Algorithm Monad
  -- $monad
    InterT(..)
  , Index
  , InterPars(..)
  , xfreeSync
  , lift
  -- , catch
  -- * Syntax
  -- $actions
  , InterActions(..)
  -- * Execution with Oracle
  -- $eval
  , runWithOracles
  , OracleCaller
  , OracleWrapper(..)
  , Oracle
  , OracleReq(..)
  , runWithOracles1
  , runWithOracles2
  -- * Step-by-step Execution
  -- $step
  , runTillSend
  , SendRes(..)
  , runTillRecv
  , RecvRes(..)
  , runTillHalt
  -- ** Helper lemmas
  -- $lemmas
  , mayOnlyRecvVoidPrf
  , mayOnlyRecvWTPrf
  , mayOnlySendWTPrf
  , cannotEscapeNothingPrf
) where

-- import Prelude hiding ((>>=), return)
import qualified Control.Monad as Monad
import Data.Functor
import Data.Functor.Identity

import Control.XFreer.Join
import Control.XApplicative
import Control.XMonad
import qualified Control.XMonad.Do as M

import Unsafe.Coerce (unsafeCoerce)

-- import Data.Type.Equality ((:~:)(Refl))

import UCHS.Types
import UCHS.Monad.Class

import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad (MonadPlus(..))
import qualified Control.Monad.Trans.Class as Trans

-- |The parameters of @InterT@ that do not change throughout the execution
data InterPars = InterPars
  { stInner :: Type -> Type
  -- ^The inner monad where the local computations happen
  , stEx :: [(Type, Index)]
  -- ^Type of exceptions we throw and contexts (use @[]@ to disable exceptions)
  , stAsync :: [(Type, Type)]
  -- ^Asynchronous channels
  , stSync :: [(Type, Type)]
  -- ^Syncronous channels
  }

-- $actions
--
-- Actions are given in Free monad syntax.


-- |Defines actions for:
--
-- -
--
-- @bef@ and @aft@ are the states before and after the given action. The
-- meaning of possible states is as follows:
--
-- - `Nothing` means that asynchronous sending and recieving is disabled. This
-- state is achieved by issuing
data InterActions (st :: InterPars) (bef :: Index) (aft :: Index) a where
  RecvAction :: (SomeSndMessage ach -> a) -> InterActions ('InterPars m ex ach sch) (Just False) (Just True) a
  SendAction :: SomeFstMessage ach -> a -> InterActions ('InterPars m ex ach sch) (Just True) (Just False) a
  SendFinalAction :: SomeFstMessage ach -> a -> InterActions ('InterPars m ex ach sch) (Just True) Nothing a
  -- |Perform a call to a child, immediately getting the result
  CallAction :: Chan x y sch -> x -> (y -> a) -> InterActions ('InterPars m ex ach sch) b b a
  -- |Throw an exception.
  ThrowAction :: InList '(e, b) ex -> e -> InterActions ('InterPars m ex ach sch) b b' a

  -- |Run a local action in the inner monad.
  LiftAction :: m x -> (x -> a) -> InterActions ('InterPars m ex ach sch) b b a

instance Functor (InterActions st bef aft) where
  fmap f (RecvAction cont) = RecvAction $ f . cont
  fmap f (SendAction m r) = SendAction m $ f r
  fmap f (SendFinalAction m r) = SendFinalAction m $ f r
  fmap f (CallAction i m cont) = CallAction i m $ f . cont
  fmap _ (ThrowAction i e) = ThrowAction i e
  fmap f (LiftAction m cont) = LiftAction m $ f . cont

-- $monad

-- |The monad for expressing interactive algorithms.
--
-- By instantiating @InterT@ with different parameters, you can finely
-- control what side-effects you allow:
--
-- - Local computations in Monad `stInner st`.
-- - Syncronous calls to oracle interfaces in `stSync st`.
-- - Asynchronous communcation over interfaces defined in `stAsync st`.
--
--   Asynchronous communcation depends on the `Index` state of `InnerT`. There
--   are three possible index states which are interpreted as follows.
--
--   - `Nothing` means that asyncronous communcation is disabled.
--   - `Just True` means that it's our turn to send.
--   - `Just False` means that it's our turn to receive (we currently have one
--     message in our inbox).
--
--   The states `Just True` and `Just False` are toggled with `send` and
--   `recvAny`. The state `Nothing` is reached via `sendFinal` and stays
--   this way until the algorithm terminates. Any asyncronous algorithm will
--   alternate between `send` and `recvAny` some number of times, until it
--   terminates or calls `sendFinal` (and then terninates).
--
-- - @bef@ and @aft@ specify whether this action consumes and/or produces the Write Token.
newtype InterT (st :: InterPars)
              (bef :: Index) -- ^State before an action
              (aft :: Index) -- ^State after an action
              a -- ^Returned value
    = InterT { fromSyncAlgo :: XFree (InterActions st) bef aft a }

  deriving (Functor) via (XFree (InterActions st) bef aft)
  deriving (XApplicative, XMonad) via (XFree (InterActions st))

instance Applicative (InterT st bef bef) where
  f <*> m = InterT $ fromSyncAlgo f <*> fromSyncAlgo m
  pure = InterT . pure

instance Monad (InterT st bef bef) where
  m >>= f = InterT $ fromSyncAlgo m Monad.>>= (fromSyncAlgo . f)

xfreeSync :: InterActions st bef aft a -> InterT st bef aft a
xfreeSync = InterT . xfree

-- Sync

lift :: m a -> InterT ('InterPars m ex up down) b b a
lift m = xfreeSync $ LiftAction m id

instance Print m => Print (InterT ('InterPars m ex up down) b b) where
  debugPrint = lift . debugPrint

instance Rand m => Rand (InterT ('InterPars m ex up down) b b) where
  rand = lift $ rand

instance XThrow (InterT ('InterPars m ex up down)) ex where
  xthrow i ex = xfreeSync $ ThrowAction i ex

instance XCatch
    (InterT ('InterPars m ex up down))
    ex
    (InterT ('InterPars m ex' up down))
  where
    xcatch (InterT a) h = InterT $ xcatch' a $ \i e -> fromSyncAlgo (h i e)
      where
        xcatch' :: XFree (InterActions ('InterPars m ex up down)) bef aft a
                -> (forall e b. InList '(e, b) ex -> e -> XFree (InterActions ('InterPars m ex' up down)) b aft a)
                -> XFree (InterActions ('InterPars m ex' up down)) bef aft a
        xcatch' (Pure x) _ = xreturn x
        xcatch' (Join a') h' = case a' of
            RecvAction cont -> Join $ RecvAction $ (`xcatch'` h') . cont
            SendAction x r -> Join $ SendAction x $ r `xcatch'` h'
            SendFinalAction x r -> Join $ SendFinalAction x $ r `xcatch'` h'
            CallAction i m cont -> Join $ CallAction i m $ (`xcatch'` h') . cont
            ThrowAction i e -> h' i e
            LiftAction m cont -> Join $ LiftAction m $ (`xcatch'` h') . cont

instance GetWT (InterT ('InterPars m ex up down)) where
  getWT = pure $ getSMaybeBool

instance Async (InterT ('InterPars m ex ach sch)) ach where
  sendMess m = xfreeSync $ SendAction m ()
  sendMessFinal m = xfreeSync $ SendFinalAction m ()
  recvAny = xfreeSync $ RecvAction id

instance Sync (InterT ('InterPars m ex ach sch)) sch where
  call i x = xfreeSync $ CallAction i x id

-- $step
--
-- The following functions let you evaluate an interactive algorithm
-- step-by-step. An algorithm in `True` state can be ran until it sends
-- something (or halts, or does an oracle call) via `runTillSend`, and an
-- algorithm in `False` state can be executed until it reqests a message for
-- reception (or halts, or does an oracle call) via `runTillRecv`.

-- |The result of `runTillSend`
data SendRes (m :: Type -> Type) (ach :: [(Type, Type)]) (sch :: [(Type, Type)]) (aft :: Index) a where
  -- |Algorithm called `send` or `yield`.
  SrSend :: SomeFstMessage ach
         -> InterT ('InterPars m '[] ach sch) (Just False) aft a
         -> SendRes m ach sch aft a
  -- |Algorithm called `sendFinal`.
  SrSendFinal :: SomeFstMessage ach
              -> InterT ('InterPars m '[] ach sch) Nothing aft a
              -> SendRes m ach sch aft a
  -- |Algorithm has called an oracle via `call`
  SrCall :: Chan x y sch
         -> x
         -> (y -> InterT ('InterPars m '[] ach sch) (Just True) aft a)
         -> SendRes m ach sch aft a
  -- |Algorithm halted without sending anything
  SrHalt :: a -> SendRes m ach sch (Just True) a

-- |Given `InterT` action starting in `True` state (holding write token), run
-- it until it does `call`, `send` or halts.
runTillSend :: Monad m
            => InterT ('InterPars m '[] up down) (Just True) b a
            -> m (SendRes m up down b a)
runTillSend (InterT (Pure v)) = pure $ SrHalt v
runTillSend (InterT (Join v)) = case v of
  SendAction x r -> pure $ SrSend x $ InterT r
  SendFinalAction x r -> pure $ SrSendFinal x $ InterT r
  CallAction i x cont -> pure $ SrCall i x $ InterT . cont
  ThrowAction contra _ -> case contra of {}
  LiftAction m cont -> m >>= runTillSend . InterT . cont

-- |The result of `runTillRecv`.
data RecvRes m up down aft a where
  -- |Algorithm ran `accept`
  RrRecv :: InterT ('InterPars m '[] up down) (Just True) aft a
         -> RecvRes m up down aft a
  -- |Algorithm issued an oracle call to a child via `call`
  RrCall :: Chan x y down
         -> x
         -> (y -> InterT ('InterPars m '[] up down) (Just False) aft a)
         -> RecvRes m up down aft a
  -- |Algorithm has halter without accepting a call
  RrHalt :: a
         -> RecvRes m up down (Just False) a

-- |Given an action that starts in a `False` state (no write token),
-- runTillRecv the oracle call from its parent (running it until it receives
-- the write token via `recvAny`).
runTillRecv :: Monad m
        => SomeSndMessage ach
        -> InterT ('InterPars m '[] ach sch) (Just False) b a
        -> m (RecvRes m ach sch b a)
runTillRecv _ (InterT (Pure v)) = pure $ RrHalt v
runTillRecv m (InterT (Join v)) = case v of
  RecvAction cont -> pure $ RrRecv $ InterT $ cont m
  CallAction i x cont -> pure $ RrCall i x $ InterT . cont
  ThrowAction contra _ -> case contra of {}
  LiftAction a cont -> a >>= runTillRecv m . InterT . cont

-- |Run an action until it terminates, return its result.
--
-- If the action tries to send or receive, return nothing.
runTillHalt :: Monad m
            => InterT ('InterPars m '[] ach sch) b b' a
            -> m (Maybe a)
runTillHalt (InterT (Pure x)) = pure $ Just x
runTillHalt (InterT (Join cont)) = case cont of
  RecvAction _ -> pure Nothing
  SendAction _ _ -> pure Nothing
  SendFinalAction _ _ -> pure Nothing
  CallAction _ _ _ -> pure Nothing
  ThrowAction contra _ -> case contra of {}
  LiftAction m cont' -> do
    v <- m
    runTillHalt $ InterT $ cont' v

  -- RecvAction :: (SomeSndMessage ach -> a) -> InterActions ('InterPars m ex ach sch) False True a
  -- SendAction :: SomeFstMessage ach -> a -> InterActions ('InterPars m ex ach sch) True False a
  -- -- |Perform a call to a child, immediately getting the result
  -- CallAction :: Chan x y sch -> x -> (y -> a) -> InterActions ('InterPars m ex ach sch) b b a
  -- -- |Throw an exception.
  -- ThrowAction :: InList '(e, b) ex -> e -> InterActions ('InterPars m ex ach sch) b b' a

  -- -- |Run a local action in the inner monad.
  -- LiftAction :: m x -> (x -> a) -> InterActions ('InterPars m ex ach sch) b b a

-- $eval
--
-- The following are definitions related to running an algorithm with an given
-- oracle. The `runWithOracles` executes an algorithm with an oracle, while
-- `OracleCaller` and `OracleWrapper` are convenient type synonyms
-- for the interactive algorithms that define the oracle caller and oracle
-- respectively.
--
-- The oracle is expected to terminate and produce the result `s` right after
-- receiving special request `OracleReqHalt`, but not before then. If the
-- oracle violates this condition, the `runWithOracles` fails with `mzero`. To
-- differentiate between service `OracleReqHalt` and the regular queries from
-- the algorithm, we wrap the latter in `OracleReq` type.

-- |An algorithm with no parent and with access to child oracles given by
-- `down`. Starts and finished holding the write token.
type OracleCaller m down a =
  InterT ('InterPars m '[] '[] down) (Just True) (Just True) a

-- |An algorithm serving oracle calls from parent, but not having access to
-- any oracles of its own and not returning any result.
type Oracle (m :: Type -> Type) (up :: (Type, Type)) (ret :: Type) =
  InterT ('InterPars m '[] '[ '(Snd up, OracleReq (Fst up))] '[]) (Just False) (Just True) ret

-- |Version of `Oracle` that's wrapped in newtype, convenient for use with `HList2`.
newtype OracleWrapper (m :: Type -> Type) (up :: (Type, Type)) (ret :: Type) =
  OracleWrapper
    { runOracleWrapper
      :: Oracle m up ret
    }

data OracleReq a = OracleReqHalt | OracleReq a

-- |Given main algorithm `top` and a list of oracle algorithms `bot`,
-- `runWithOracles top bot` will run them together (`top` querying any oracle
-- the oracles in `bot`) and return their results.
--
-- The `top` returns its result directly when terminating, then a special
-- `OracleReqHalt` message is sent to all of `bot` to ask them to terminate and
-- return their results.
--
-- We throw a `mzero` error in case an oracle does not follow the termination
-- condition: terminates before receiving `OracleReqHalt` or tries to respond
-- to `OracleReqHalt` instead of terminating.
--
-- Note that `runWithOracles` passes all the messages between the running
-- interactive algorithms, therefore its result is a non-interactive algorithm.
runWithOracles :: forall m (down :: [(Type, Type)]) (rets :: [Type]) a.
               (Monad m, SameLength down rets)
               => OracleCaller m down a
               -- ^The oracle caller algorithm
               -> HList2 (OracleWrapper m) down rets
               -- ^The implementations of oracles available to caller
               -> MaybeT m (a, HList Identity rets)
               -- ^The outputs of caller and oracle. Fails with `mzero` if
               -- the oracle terminates before time or doesn't terminate when
               -- requested
runWithOracles = \top bot -> Trans.lift (runTillSend top) >>= \case
    SrSend (SomeFstMessage contra _) _ -> case contra of {}
    SrSendFinal (SomeFstMessage contra _) _ -> case contra of {}
    SrHalt r -> do
      s <- haltAll bot
      pure (r, s)
    SrCall i m cont -> do
      (bot', r) <- forIthFst i bot $ oracleCall m
      runWithOracles (cont r) bot'
  where
    oracleCall :: x
               -> OracleWrapper m '(x, y) s
               -> MaybeT m (OracleWrapper m '(x, y) s, y)
    oracleCall m (OracleWrapper bot) = Trans.lift (runTillRecv (SomeSndMessage Here (OracleReq m)) bot) >>= \case
      RrCall contra _ _ -> case contra of {}
      RrRecv cont -> Trans.lift (runTillSend cont) >>= \case
        SrCall contra _ _ -> case contra of {}
        SrHalt _ -> mzero
        SrSend r bot' -> case r of
            SomeFstMessage Here r' -> pure (OracleWrapper bot', r')
            SomeFstMessage (There contra) _ -> case contra of {}
        SrSendFinal _ bot' -> case cannotEscapeNothingPrf bot' of {}
          
    halt :: OracleWrapper m up x
         -> MaybeT m x
    halt (OracleWrapper bot) = Trans.lift (runTillRecv (SomeSndMessage Here OracleReqHalt) bot) >>= \case
      RrCall contra _ _ -> case contra of {}
      RrRecv cont -> Trans.lift (runTillSend cont) >>= \case
        SrCall contra _ _ -> case contra of {}
        SrHalt s -> pure s
        SrSend _ _ -> mzero
        SrSendFinal _ bot' -> case cannotEscapeNothingPrf bot' of {}

    haltAll :: forall (down' :: [(Type, Type)]) (rets' :: [Type]).
               HList2 (OracleWrapper m) down' rets'
            -> MaybeT m (HList Identity rets')
    haltAll = \case
      HNil2 -> pure HNil
      HCons2 x xs -> do
        x' <- halt x
        xs' <- haltAll xs
        pure $ HCons (Identity x') xs'

-- |Version of `runWithOracles` that accepts only one oracle
runWithOracles1 :: Monad m
                => OracleCaller m '[ '(x, y) ] a
                -> OracleWrapper m '(x, y) b
                -> MaybeT m (a, b)
runWithOracles1 top bot = runWithOracles top (HList2Match1 bot) <&>
  \(a, HListMatch1 (Identity b)) -> (a, b)

-- |Version of `runWithOracles` that accepts two oracles
runWithOracles2 :: Monad m
                => OracleCaller m '[ '(x, y), '(x', y') ] a
                -> OracleWrapper m '(x, y) b
                -> OracleWrapper m '(x', y') b'
                -> MaybeT m (a, b, b')
runWithOracles2 top bot bot' = runWithOracles top (HList2Match2 bot bot') <&>
  \(a, HListMatch2 (Identity b) (Identity b')) -> (a, b, b')

-- $lemmas
--
-- These lemmas make it easier to extract the contents of `RecvRes` and
-- `SendRes` in cases when types guarrantee that these values can be
-- deconstructed in only one way (i.e. there is only one value constrctor that
-- could have produces the value of this type).
--
-- These helpers allow (when applicable) you to write a sequence of
-- `runTillRecv` and `runTillSend` in a linear fashion. You can do
--
-- @
-- do
--   x \<- `mayOnlyRecvVoidPrf` \<$> `runTillRecv` _ _
--   (y, cont) \<- `mayOnlySendWTPrf` \<$> `runTillSend` _
--   _
-- @
--
-- instead of manually proving that some constructors are impossible as below.
--
-- @
-- do
--   `runTillRecv` _ _ `>>=` \case
--     `RrCall` contra _ _ -> case contra of {}
--     `RrHalt` contra -> case contra of {}
--     `RrRecv` x -> do
--       `runTillSend` _ `>>=` \case
--         `SrCall` contra _ _ -> case contra of {}
--         `SrSend` y cont -> do
--           _
-- @

-- |Proof: an interactive computation that starts in `Nothing` state and does
-- not use exceptions, must finish in `Nothing` state (unless it diverges).
--
-- The proof uses `unsafeCoerce`, Haskell can't verify this for us. So make
-- sure it's proven correctly on paper.
cannotEscapeNothingPrf :: InterT ('InterPars m '[] ach sch) Nothing aft a
                       -> aft :~: Nothing
cannotEscapeNothingPrf (InterT i) = case i of
  Pure v -> Refl
  Join (CallAction _ _ _) -> unsafeCoerce $ Refl @()
  Join (ThrowAction contra _) -> case contra of {}
  Join (LiftAction _ _) -> unsafeCoerce $ Refl @()
  -- ^Here, we know by induction that the programmer can't escape
  -- `Nothing`. But I don't think I can express this induction (over a sequance
  -- of nested lambdas) in Haskell, therefore the `unsafeCoerce`.

-- |Proof: A program with sync channels and return type `Void` may not
-- terminate; if it starts from `Just False` state, it will inevitably request
-- an rx message.
mayOnlyRecvVoidPrf :: RecvRes m ach '[] (Just False) Void
                   -> InterT ('InterPars m '[] ach '[]) (Just True) (Just False) Void
mayOnlyRecvVoidPrf = \case
  RrCall contra _ _ -> case contra of {}
  RrHalt contra -> case contra of {}
  RrRecv x -> x

-- |Proof: a program with no sync channels that must terminate in `(Just True)`
-- state but starts in `(Just False)` state will inevitably request an rx
-- message.
mayOnlyRecvWTPrf :: RecvRes m ach '[] (Just True) a
                 -> InterT ('InterPars m '[] ach '[]) (Just True) (Just True) a
mayOnlyRecvWTPrf = \case
  RrCall contra _ _ -> case contra of {}
  RrRecv x -> x

-- |Proof: a program with no sync channels that must terminate in `Just False`
-- state that starts from `Just True` state will inevitable produce a tx
-- message.
mayOnlySendWTPrf :: SendRes m ach '[] (Just False) a
       -> (SomeFstMessage ach, InterT ('InterPars m '[] ach '[]) (Just False) (Just False) a)
mayOnlySendWTPrf = \case
  SrCall contra _ _ -> case contra of {}
  SrSendFinal _ cont -> case cannotEscapeNothingPrf cont of {}
  SrSend x cont -> (x, cont)
