module LUCk.Games.Common where

import LUCk.Types
import LUCk.Monad.Class
import LUCk.Monad.Algo
import LUCk.Monad.Async
import LUCk.Monad.Extra
import LUCk.Monad.InterT.Eval.Oracle

import Control.XMonad
import Control.Monad.Free
-- import Control.XFreer.Join
import qualified Control.XMonad.Do as M

import Data.Maybe (isJust, fromMaybe)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad (MonadPlus(..))

-- |Oracle that computes the given monadic function upon request. When
-- requested to terminate, returns the list of all request-response pairs it
-- got.
oracleMapM :: (Monad m)
           => (a -> m b)
           -> OracleWrapper m '(a, b) [(a, b)]
oracleMapM f = OracleWrapper $ M.do
  recvOne >>=: \case
    OracleReqHalt -> xreturn []
    OracleReq x -> M.do
      y <- lift $ f x
      sendOne y
      rest <- runOracleWrapper $ oracleMapM f
      xreturn $ (x, y) : rest

assert :: MonadPlus m => Bool -> m ()
assert True = pure ()
assert False = mzero

evalMaybeT :: Functor m => a -> MaybeT m a -> m a
evalMaybeT v m = fromMaybe v <$> runMaybeT m

-- |Calculate the probability of a random event
pr :: Algo False True Bool -> Rational
pr a = case runAlgo a of
  Pure True -> 1
  Pure False -> 0
  Free (RandAction cont) -> (pr (Algo $ cont False) + pr (Algo $ cont True)) / 2
