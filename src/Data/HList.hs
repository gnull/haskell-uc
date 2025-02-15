{-# LANGUAGE AllowAmbiguousTypes #-}

module Data.HList where

import Prelude hiding ((!!), (++))

import Data.Kind (Type, Constraint)
import Data.Type.Equality ((:~:)(Refl), TestEquality(..))

import Data.Functor.Identity

import Control.Arrow (first, second)

-- * Dependent pointer into a list

-- |Dependent index of an element of type @(x, y)@ in list @xs@
--
-- We use lists of pairs to encode the ports an algorithm has access to,
-- as well heterogenous lists @HList@ that occur during interpretation of our
-- algorithms. And this type serves as a pointer into one of such ports in
-- the list.
type InList :: forall a. [a] -> a -> Type
data InList xs x where
    Here :: InList (x : xs) x
    There :: InList xs x -> InList (y : xs) x

pattern There2 :: InList xs x -> InList (y0 : y1 : xs) x
pattern There2 i = There (There i)
{-# COMPLETE There2 #-}

pattern There3 :: InList xs x -> InList (y0 : y1 : y2 : xs) x
pattern There3 i = There (There2 i)
{-# COMPLETE There3 #-}

pattern There4 :: InList xs x -> InList (y0 : y1 : y2 : y3 : xs) x
pattern There4 i = There (There3 i)
{-# COMPLETE There4 #-}

pattern There5 :: InList xs x -> InList (y0 : y1 : y2 : y3 : y4 : xs) x
pattern There5 i = There (There4 i)
{-# COMPLETE There5 #-}

pattern There6 :: InList xs x -> InList (y0 : y1 : y2 : y3 : y4 : y5 : xs) x
pattern There6 i = There (There5 i)
{-# COMPLETE There6 #-}

pattern InList0 :: InList (x : xs) x
pattern InList0 = Here
{-# COMPLETE InList0 #-}

pattern InList1 :: InList (y0 : x : xs) x
pattern InList1 = There Here
{-# COMPLETE InList1 #-}

pattern InList2 :: InList (y0 : y1 : x : xs) x
pattern InList2 = There2 Here
{-# COMPLETE InList2 #-}

pattern InList3 :: InList (y0 : y1 : y2 : x : xs) x
pattern InList3 = There3 Here
{-# COMPLETE InList3 #-}

pattern InList4 :: InList (y0 : y1 : y2 : y3 : x : xs) x
pattern InList4 = There4 Here
{-# COMPLETE InList4 #-}

pattern InList5 :: InList (y0 : y1 : y2 : y3 : y4 : x : xs) x
pattern InList5 = There5 Here
{-# COMPLETE InList5 #-}

pattern InList6 :: InList (y0 : y1 : y2 : y3 : y4 : y5 : x : xs) x
pattern InList6 = There6 Here
{-# COMPLETE InList6 #-}

data SomeIndex xs where
    SomeIndex :: InList xs x -> SomeIndex xs

data SomeValue xs where
  SomeValue :: InList xs x -> x -> SomeValue xs

-- |Compare two indices for equality
instance TestEquality (InList xs) where
  -- testEquality :: InList x xs -> InList y xs -> Maybe (x :~: y)
  testEquality Here Here = Just Refl
  testEquality (There a) (There b) = testEquality a b
  testEquality _ _ = Nothing

-- |Pad the index to make it valid after applying @(::)@ to the list.
padMessageIndex :: SomeValue ts -> SomeValue (t : ts)
padMessageIndex (SomeValue i' x') = SomeValue (There i') x'

-- * Port Lists

-- |A port is defined by a pair of types.
--
-- - @A `:>` B@ allows asyncronously sending values of type @A@ and receiving @B@.
-- - @A `:|>` B@ allows to do the same syncronously,
-- - @A `:>|` B@ allows serving syncronous requests.
data Port = Type :> Type
          -- | Type :|> Type
          -- | Type :>| Type

type PortTxType :: Port -> Type
type family PortTxType p where
  PortTxType (x :> _) = x

type PortRxType :: Port -> Type
type family PortRxType p where
  PortRxType (_ :> x) = x

type PortDual :: Port -> Port
type family PortDual p where
  PortDual (x :> y) = y :> x
  -- PortDual (x :|> y) = y :>| x
  -- PortDual (x :>| y) = y :|> x

-- |A pointer into the list of ports @xs@.
--
-- The @`PortInList` x y xs@ is a proof of @x `:>` y@ being in @xs@.
type PortInList :: Type -> Type -> [Port] -> Type
type PortInList x y xs = InList xs (x :> y)

type Fst :: forall a b. (a, b) -> a
type family Fst p where
  Fst '(x, _) = x

type MapFst :: forall a b. [(a, b)] -> [a]
type family MapFst l where
  MapFst '[] = '[]
  MapFst ( '(x, y) : l) = x : MapFst l

type Snd :: forall a b. (a, b) -> b
type family Snd p where
  Snd '(_, y) = y

type Zip :: forall a b. [a] -> [b] -> [(a, b)]
type family Zip l l' where
  Zip '[] '[] = '[]
  Zip (x:xs) (y:ys) = '(x, y) : Zip xs ys

data SomeRxMess xs where
  SomeRxMess :: InList xs p -> PortRxType p -> SomeRxMess xs

data SomeTxMess xs where
  SomeTxMess :: InList xs p -> PortTxType p -> SomeTxMess xs

-- * Heterogenous Lists
--
-- This defines a list where values may have different types,
-- as prescribed by the list type's index.

-- |Heterogenous List
type HList :: forall a. (a -> Type) -> [a] -> Type
data HList f (types :: [a]) where
    HNil :: HList f '[]
    HCons :: f t -> HList f ts -> HList f (t : ts)

data KnownHPPortsD ports where
  KnownHPPortsZ :: KnownHPPortsD '[]
  KnownHPPortsS :: KnownHPPortsD ports
              -> KnownHPPortsD ((HListPair xl xr) :> (HListPair yl yr) : ports)

type HListPair l r = (HList Identity l, HList Identity r)

type family Concat2 l r p where
  -- Concat2 '[] '[] p = p
  Concat2 l r (HListPair lx rx :> HListPair ly ry)
    =    HListPair (Concat l lx) (Concat r rx)
      :> HListPair (Concat l ly) (Concat r ry)

type family MapConcat2 l r ports where
  -- MapConcat2 '[] '[] ports = ports
  MapConcat2 _ _ '[] = '[]
  MapConcat2 l r (p : ports)
    = Concat2 l r p : MapConcat2 l r ports

(++) :: HList f l -> HList f r -> HList f (Concat l r)
HNil ++ ys = ys
HCons x xs ++ ys = HCons x $ xs ++ ys

(+++) :: HListPair l r
      -> HListPair l' r'
      -> HListPair (Concat l l') (Concat r r')
(l, r) +++ (l', r') = (l ++ l', r ++ r')

class KnownHPPorts ports where
  getKnownHPPorts :: KnownHPPortsD ports

instance KnownHPPorts '[] where
  getKnownHPPorts = KnownHPPortsZ

instance (KnownHPPorts ports, p ~ HListPair xl xr :> HListPair yl yr)
  => KnownHPPorts (p:ports) where
    getKnownHPPorts = KnownHPPortsS getKnownHPPorts

-- |Signleton type to express the list structure (length) but not the contents.
data KnownLenD :: forall a. [a] -> Type where
  KnownLenZ :: KnownLenD '[]
  KnownLenS :: forall a (x :: a) (l :: [a]). KnownLenD l -> KnownLenD (x : l)

-- |Class of list values for which their length is known at compile time.
type KnownLen :: forall a. [a] -> Constraint
class KnownLen l where
  getKnownLenPrf :: KnownLenD l

instance KnownLen '[] where
  getKnownLenPrf = KnownLenZ

instance KnownLen xs => KnownLen (x:xs) where
  getKnownLenPrf = KnownLenS $ getKnownLenPrf @_ @xs

data SameLenD :: forall a b. [a] -> [b] -> Type where
  SameLenNil :: SameLenD '[] '[]
  SameLenCons :: SameLenD l l' -> SameLenD (x:l) (x':l')

type SameLen :: forall a b. [a] -> [b] -> Constraint
class SameLen l l' where
  proveSameLength :: SameLenD l l'

instance SameLen '[] '[] where
  proveSameLength = SameLenNil

instance SameLen l l' => SameLen (x:l) (x':l') where
  proveSameLength = SameLenCons proveSameLength

type Concat :: forall a. [a] -> [a] -> [a]
type family Concat xs ys where
  Concat '[] ys = ys
  Concat (x:xs) ys = x:Concat xs ys

-- |Proof of `p ++ (p' ++ s') == (p ++ p') ++ s'`.
concatAssocPrf :: forall p p' s' l s.
                  ListSplitD l p s
               -> (Concat p (Concat p' s')) :~: (Concat (Concat p p') s')
concatAssocPrf = \case
  SplitHere -> Refl
  SplitThere i -> case concatAssocPrf @_ @p' @s' i of
    Refl -> Refl

concatInjPrf :: forall xs ys ys'.
             Concat xs ys :~: Concat xs ys'
             -> KnownLenD xs
             -> ys :~: ys'
concatInjPrf Refl = \case
  KnownLenZ -> Refl
  KnownLenS rest -> concatInjPrf Refl rest

-- |Statement @`ListSplitD` l p s@ says that @l = p ++ s@, i.e. that @l@ can be
-- cut into prefix @p@ and suffix @s@.
--
-- Structure-wise, this is just a pointer, like `InList`, but it carries
-- different information on type-level.
data ListSplitD :: forall a. [a] -> [a] -> [a] -> Type where
  SplitHere :: ListSplitD l '[] l
  SplitThere :: ListSplitD l p s -> ListSplitD (x:l) (x:p) s

type ListSplitConcat p s = ListSplitD (Concat p s) p s

class ListSplit l p s where
  getListSplit :: ListSplitD l p s

instance (KnownLen p, l ~ Concat p s) => ListSplit l p s where
  getListSplit = getListSplit' getKnownLenPrf

getListSplit' :: KnownLenD p
              -> ListSplitD (Concat p s) p s
getListSplit' = \case
    KnownLenZ -> SplitHere
    KnownLenS i -> SplitThere $ getListSplit' i

listSplitConcat :: ListSplitD l p s
                -> Concat p s :~: l
listSplitConcat = \case
  SplitHere -> Refl
  SplitThere i -> case listSplitConcat i of
    Refl -> Refl

listSplitAdd :: ListSplitD l p s
             -> ListSplitD s p' s'
             -> ListSplitD l (Concat p p') s'
listSplitAdd = \case
  SplitHere -> id
  SplitThere i -> \j -> SplitThere $ listSplitAdd i j

listConcatSplit :: ListSplitD l p s
                -> ListSplitD (Concat p s') p s'
listConcatSplit SplitHere = SplitHere
listConcatSplit (SplitThere i) = SplitThere $ listConcatSplit i

listSplitPopSuffix :: ListSplitD (Concat p (x:s)) p (x:s)
                   -> ListSplitD (Concat p s) p s
listSplitPopSuffix = \case
  SplitHere -> SplitHere
  SplitThere i -> SplitThere $ listSplitPopSuffix i

listSplitSubst :: ListSplitD l' p' (s:rest)
               -> ListSplitConcat p' (f:rest)
listSplitSubst = \case
  SplitHere -> SplitHere
  SplitThere i -> SplitThere $ listSplitSubst i

listSplitSwap :: ListSplitD l p (f:l')
              -> ListSplitD l' p' (s:rest)
              -> ( ListSplitConcat p (s:(Concat p' (f:rest)))
                 , ListSplitConcat p' (f:rest)
                 )
listSplitSwap = \case
  SplitHere -> \p -> (SplitHere, listSplitSubst p)
  SplitThere i -> \p -> first SplitThere $ listSplitSwap i p

listSplitSuff2 :: ListSplitD l p (f:l')
               -> ListSplitD l' p' (s:rest)
               -> ( ListSplitConcat p (Concat p' rest)
                  , ListSplitConcat p' rest
                  )
listSplitSuff2 = \case
  SplitHere -> \p -> case listSplitConcat p of
    Refl -> (SplitHere, listSplitPopSuffix p)
  SplitThere i -> \p -> first SplitThere $ listSplitSuff2 i p


-- instance ListSplit l '[] l where
--   getListSplit = SplitHere
-- instance ListSplit l p s => ListSplit (x:l) (x:p) s where
--   getListSplit = SplitThere getListSplit

pattern Split0 :: ListSplitD l '[] l
pattern Split0 = SplitHere
{-# COMPLETE Split0 #-}

pattern Split1 :: ListSplitD (x0 : l) '[x0] l
pattern Split1 = SplitThere Split0
{-# COMPLETE Split1 #-}

pattern Split2 :: ListSplitD (x0 : x1 : l)
                            (x0 : '[x1]) l
pattern Split2 = SplitThere Split1
{-# COMPLETE Split2 #-}

pattern Split3 :: ListSplitD (x0 : x1 : x2 : l)
                            (x0 : x1 : '[x2]) l
pattern Split3 = SplitThere Split2
{-# COMPLETE Split3 #-}

pattern Split4 :: ListSplitD (x0 : x1 : x2 : x3 : l)
                            (x0 : x1 : x2 : '[x3]) l
pattern Split4 = SplitThere Split3
{-# COMPLETE Split4 #-}

pattern Split5 :: ListSplitD (x0 : x1 : x2 : x3 : x4 : l)
                            (x0 : x1 : x2 : x3 : '[x4]) l
pattern Split5 = SplitThere Split4
{-# COMPLETE Split5 #-}

hlistDrop :: ListSplitD l p s
          -> HList f l
          -> HList f s
hlistDrop SplitHere xs = xs
hlistDrop (SplitThere i) (HCons _ xs) = hlistDrop i xs

hlistTakeHead :: HList f (x:xs)
          -> HList f '[x]
hlistTakeHead (HCons x _) = HCons x HNil

pattern HListMatch0 :: HList f '[]
pattern HListMatch0 = HNil
{-# COMPLETE HListMatch0 #-}

pattern HListMatch1 :: f a -> HList f '[a]
pattern HListMatch1 a = HCons a HNil
{-# COMPLETE HListMatch1 #-}

pattern HListMatch2 :: f a -> f a' -> HList f '[a, a']
pattern HListMatch2 a a' = HCons a (HListMatch1 a')
{-# COMPLETE HListMatch2 #-}

pattern HListMatch3 :: f a -> f a' -> f a'' -> HList f '[a, a', a'']
pattern HListMatch3 a a' a'' = HCons a (HListMatch2 a' a'')
{-# COMPLETE HListMatch3 #-}

-- |Heterigenous zip of two lists
type HList2 :: forall a b. (a -> b -> Type) -> [a] -> [b] -> Type
data HList2 f (x :: [a]) (y :: [b]) where
    HNil2 :: HList2 f '[] '[]
    HCons2 :: f x y -> HList2 f xs ys -> HList2 f (x:xs) (y:ys)


pattern HList2Match0 :: HList2 f '[] '[]
pattern HList2Match0 = HNil2
{-# COMPLETE HList2Match0 #-}

pattern HList2Match1 :: f a b -> HList2 f '[a] '[b]
pattern HList2Match1 a = HCons2 a HNil2
{-# COMPLETE HList2Match1 #-}

pattern HList2Match2 :: f a b -> f a' b' -> HList2 f '[a, a'] '[b, b']
pattern HList2Match2 a a' = HCons2 a (HList2Match1 a')
{-# COMPLETE HList2Match2 #-}

pattern HList2Match3 :: f a b -> f a' b' -> f a'' b'' -> HList2 f '[a, a', a''] '[b, b', b'']
pattern HList2Match3 a a' a'' = HCons2 a (HList2Match2 a' a'')
{-# COMPLETE HList2Match3 #-}

-- |Fetch the value under given index. Statically checked version of @Prelude.(!!)@.
(!!) :: HList f types -> InList types x -> f x
(!!) (HCons x _) Here = x
(!!) (HCons _ xs) (There t) = xs !! t
(!!) HNil contra = case contra of

-- |Applies given mutating action to one of the elements in the list
forIthFst :: Monad m
       => InList xs x
       -- ^Element index
       -> HList2 f xs ys
       -- ^List
       -> (forall y. f x y -> m (f x y, z))
       -- ^Action
       -> m (HList2 f xs ys, z)
forIthFst Here (HCons2 x xs) f = do
  (x', z) <- f x
  pure (HCons2 x' xs, z)
forIthFst (There i) (HCons2 x xs) f = do
  (xs', z) <- forIthFst i xs f
  pure (HCons2 x xs', z)

-- |Applies given mutating action to one of the elements in the list
forIth :: Monad m
            => InList types x
            -- ^Action
            -> HList f types
            -- ^Element index
            -> (f x -> m (f x, z))
            -- ^List
            -> m (HList f types, z)
forIth Here (HCons x xs) f = do
  (x', z) <- f x
  pure (HCons x' xs, z)
forIth (There i) (HCons x xs) f = do
  (xs', z) <- forIth i xs f
  pure (HCons x xs', z)

-- |Like `map`, but for `HList`.
hMap :: (forall a. InList types a -> f a -> g a) -> HList f types -> HList g types
hMap f = \case
  HNil -> HNil
  HCons x xs -> HCons (f Here x) $ hMap (\i-> f $ There i) xs

-- |Convert @HList@ to a regular list.
homogenize
  :: forall t (types :: [t]) (f :: t -> Type) a.
     (forall x. InList types x -> f x -> a)
  -> HList f types
  -> [a]
homogenize _ HNil = []
homogenize g (HCons x xs) = g Here x : homogenize (g . There) xs

knownLenToSplit :: KnownLenD p
                -> ListSplitD (Concat p s) p s
knownLenToSplit KnownLenZ = SplitHere
knownLenToSplit (KnownLenS i) = SplitThere $ knownLenToSplit i

splitHList :: ListSplitD l p s
           -> HList f l
           -> (HList f p, HList f s)
splitHList SplitHere l = (HNil, l)
splitHList (SplitThere i) (HCons x xs) = (HCons x p, s)
  where (p, s) = splitHList i xs

someRxMessThere :: SomeRxMess ports'
                -> SomeRxMess (x : ports')
someRxMessThere (SomeRxMess i m) = SomeRxMess (There i) m


data ConstrAllD (c :: Type -> Constraint) (l :: [Type]) where
  ConstrAllNil :: ConstrAllD c '[]
  ConstrAllCons :: c t
                => ConstrAllD c l
                -> ConstrAllD c (t:l)

knownLenfromConstrAllD :: ConstrAllD c l -> KnownLenD l
knownLenfromConstrAllD ConstrAllNil = KnownLenZ
knownLenfromConstrAllD (ConstrAllCons xs) = KnownLenS $ knownLenfromConstrAllD xs

class ConstrAll c l where
  getConstrAllD :: ConstrAllD c l

instance ConstrAll c '[] where
  getConstrAllD = ConstrAllNil

instance (c t, ConstrAll c l) => ConstrAll c (t:l) where
  getConstrAllD = ConstrAllCons getConstrAllD

data HListShow l where
  HListShow :: ConstrAllD Ord l
            -> HList Identity l
            -> HListShow l

instance Eq (HListShow l) where
  x == y = compare x y == EQ

instance Ord (HListShow l) where
  compare (HListShow xPrf xs) (HListShow yPrf ys) = case (xs, xPrf, ys, yPrf) of
    (HNil, _, HNil, _) -> EQ
    (HCons x xs', ConstrAllCons xPrf', HCons y ys', ConstrAllCons yPrf') ->
         x `compare` y
      <> HListShow xPrf' xs' `compare` HListShow yPrf' ys'
