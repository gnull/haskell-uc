{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module LUCk.UC.Core where

-- import qualified Control.XMonad.Do as M
-- import Control.XMonad
-- import Control.Arrow
-- import Control.XMonad.Trans

import LUCk.Syntax
import LUCk.Types

type OnlySendPort a = a :> Void
type OnlyRecvPort a = Void :> a
type PingSendPort = OnlySendPort ()
type PingRecvPort = OnlyRecvPort ()

type Pid = String

type family Concat2 l r p where
  Concat2 l r (HListPair lx rx :> HListPair ly ry)
    =    HListPair (Concat l lx) (Concat r rx)
      :> HListPair (Concat l ly) (Concat r ry)

type family MapConcat l r ports where
  MapConcat _ _ '[] = '[]
  MapConcat l r (p : ports)
    = Concat2 l r p : MapConcat l r ports

type family AppendSids sids p where
  AppendSids sids p = Concat2 sids '[] p

type family MapAppendSids sids ports where
  MapAppendSids sids ports = MapConcat sids '[] ports

type family ZipAppendSid sids down where
  ZipAppendSid '[] '[] = '[]
  ZipAppendSid (s:sids) (p : down)
    = (HListPair '[s] '[p])
    : ZipAppendSid sids down

type family AppendPid p where
  AppendPid p = Concat2 '[] '[Pid] p

type family MapAppendPid ports where
  MapAppendPid ports = MapConcat '[] '[Pid] ports

knownHPPortsAppendPid :: KnownHPPortsD down
                      -> KnownHPPortsD (MapAppendPid down)
knownHPPortsAppendPid KnownHPPortsZ = KnownHPPortsZ
knownHPPortsAppendPid (KnownHPPortsS i) = KnownHPPortsS $ knownHPPortsAppendPid i

-- |An interactive algorithm with that we use for defining ideal
-- functionalities and protocols.
--
-- Has the following interfaces.
--
-- - @up@ interface to its callers,
-- - @down@ interfaces to its subroutines,
-- - a single `PingSendPort` interface to yield control to the environment.
type Proto up down = AsyncT (PortDual up : down) NextRecv NextRecv Void

-- |A `Proto` where @up@ and @down@ interfaces are appropriately marked
-- with ESID and PID values to handle multiple sessions in one process.
--
-- This is used by `multiSidIdealShell` to implement multiple sessions of
-- `SingleSidIdeal` inside.
type MultSidIdeal rest sid up down =
  Proto (AppendSids (sid:rest) (AppendPid up))
        (MapAppendSids (sid:rest) (MapAppendPid down))

-- |A `Proto` that implements a single process in a real (multi-session) protocol.
type MultSidReal rest sid up down =
  HListPair '[] '[Pid] -> Proto (AppendSids (sid:rest) up)
                                (MapAppendSids (sid:rest) down)

-- |A `Proto` that implements a single session. The interface it provides
-- to its caller is maked only with PID values.
--
-- Use this with `multiSidIdealShell` to get a multi-session extension.
type SingleSidIdeal sid up down =
  HListPair '[sid] '[] -> Proto (AppendPid up)
                                (MapAppendPid down)

-- |A `Proto` that implements a single process in a real (single-session) protocol.
type SingleSidReal sid up down =
  HListPair '[sid] '[Pid] -> Proto up down
