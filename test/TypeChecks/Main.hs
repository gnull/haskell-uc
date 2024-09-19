{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors #-}

module Main where

import Test.Tasty            (TestTree, defaultMain)
import Test.Tasty.HUnit      (testCase, assertEqual)
import Test.ShouldNotTypecheck (shouldNotTypecheck)

import LUCk.Monad
import LUCk.Types

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testCase "split" $ do
    shouldNotTypecheck $ sendWithoutWt
  where
    sendWithoutWt :: Chan String String ach -> AsyncT (Algo pr ra) ach NextRecv NextRecv ()
    sendWithoutWt ch = send ch "hey"
