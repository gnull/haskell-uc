module LUCk.Monad.InterT.SomeWT where

import LUCk.Types
import LUCk.Monad.Async

-- |A computation that
--
-- 1. Starts in Write Token state `bef`,
-- 2. stops in Write Token state `i` with result `a`,
-- 3. runs the continuation given as first argument from there to finish in Write Token state `aft` with result `b`.
data ContFromAnyWT m ex ach bef aft a b
  = ContFromAnyWT ((forall i. KnownIndex i => a -> AsyncExT m ex ach i aft b) -> AsyncExT m ex ach bef aft b)

-- |A version of `ContFromAnyWT` that hides `aft` and `b` under quantifiers.
--
-- Use this if you want to define interactive computations that stop in Write
-- Token state of its choosing.
type SomeWT m ex ach bef a = forall aft b. ContFromAnyWT m ex ach bef aft a b

-- |Given a computation that starts in Write Token state `bef` and stops in
-- _some_ state of its choosing, and a way to continue from _any_ Write Token
-- state to `aft`, make a computation from `bef` to `aft`.
--
-- This effectively composes two computations, taking existential
-- quantification inside `ContFromAnyWT` into account.
dispatchSomeWT :: ContFromAnyWT m ex ach bef aft a b
               -> (forall i. KnownIndex i => a -> AsyncExT m ex ach i aft b)
               -> AsyncExT m ex ach bef aft b
dispatchSomeWT (ContFromAnyWT x) = x
