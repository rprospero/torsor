{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}

module Torsor.Containers (DiffableContainer(..), foldDiff, foldDiffM, ContainerDiff, differenceDiffableContainer, addDiffableContainer) where

import Data.Foldable (Foldable (fold), foldl')
import Data.Functor.Identity (Identity (..))
import qualified Data.IntMap as IM
import qualified Data.Map as M
import qualified Data.Map.Merge.Strict as M
import qualified Data.Sequence as S
import Torsor


data Diff v d = Add v | Drop v | Shift d
  deriving (Show, Eq)

instance Additive d => Additive [Diff v d] where
  zero = []
  invert = reverse . fmap go where
    go (Add v) = Drop v
    go (Drop v) = Add v
    go (Shift v) = Shift $ invert v
  plus = (<>)
  minus x y = x `plus` invert y

-- | A typeclass for diffing containers.  This exists entirely to
-- simplify creating Torsor instances by eliminating boilerplate
-- between containers.  The @f@ type function is our container
-- (e.g. @`Map` `String`@).  The @g@ type function annotates the
-- values which are added and removed from the container.  For
-- example, on the `IntMap`, @g@ is @(`Int`,)@, as each value added or
-- removed needs to be annotated with its key.
class DiffableContainer f g | f -> g where
  -- | The elements which have been added to the container
  gains ::
    (Applicative t, Foldable t, Monoid (t (g a))) =>
    -- | The new value
    f a ->
    -- | The old value
    f a ->
    -- | A collection of the new annotated new elements
    t (g a)

  losses ::
    (Applicative t, Foldable t, Monoid (t (g a))) =>
    -- | The new value
    f a ->
    -- | The old value
    f a ->
    -- | A collection of the elements removed from the old version by the new one
    t (g a)

  -- | Find the changed values within the container
  remained ::
    -- | The new value
    f a ->
    -- | The old value
    f a ->
    -- | A container with all of the new and old values together.  Values which were added or removed are ignored
    f (a, a)

  -- | Add an annotated element to the container
  patchIn ::
    -- | The annotated element
    g a ->
    -- | The original container
    f a ->
    -- | The updated container
    f a

  -- | Drop an element from the container
  patchOut ::
    -- | The annotated element
    g a ->
    -- | The original container
    f a ->
    -- | The updated container
    f a

  -- | Zip a function over two containers, acting on values present in
  -- both containers.  Note that it is a zip and __not__ the applicative
  -- instance.  For example
  --
  -- > zipper (+) [1, 2] [3, 4] == [4, 6]
  --
  -- while
  --
  -- > (+) <$> [1, 2] <*> [3, 4] == [4, 5, 5, 6]
  zipper :: (a -> b -> c) -> f a -> f b -> f c


-- | Build a monadic response to changes in the container
foldDiffM ::
  (DiffableContainer f g, Torsor a b, Monoid w, Monad m) =>
  -- | Response to new elements
  (g a -> m w) ->
  -- | Response to lost elements
  (g a -> m w) ->
  -- | Response to changed elements
  (f b -> m w) ->
  -- | The difference to operate over
  ContainerDiff f g a b ->
  m w
foldDiffM add drp shft = fmap fold . mapM go
  where
    go (Add x) = add x
    go (Drop x) = drp x
    go (Shift x) = shft x

-- | Build a response to changes in the container
foldDiff ::
  (DiffableContainer f g, Torsor a b, Monoid w) =>
  -- | Response to new elements
  (g a -> w) ->
  -- | Response to lost elements
  (g a -> w) ->
  -- | Response to changed elements
  (f b -> w) ->
  -- | The difference to operate over
  ContainerDiff f g a b ->
  w
foldDiff add drp shft = runIdentity . foldDiffM (Identity . add) (Identity . drp) (Identity . shft)

-- | For any @`DiffableContainer` f g@, then you can use this function
-- as the `difference` function when implementing
-- @`Torsor` (f a) (`ContainerDiff` f g a b)@
differenceDiffableContainer :: (Functor f, Foldable f, DiffableContainer f g, Torsor a b) => f a -> f a -> ContainerDiff f g a b
differenceDiffableContainer new old =
  let gain = Add <$> gains new old
      lost = Drop <$> losses new old
      shift =
        let s = uncurry difference <$> remained new old
         in pure $ Shift s
   in lost <> shift <> gain

-- | For any @`DiffableContainer` f g@, then you can use this function
-- as the `add` function when implementing
-- @`Torsor` (f a) (`ContainerDiff` f g a b)@
addDiffableContainer :: (DiffableContainer f g, Torsor a b) => ContainerDiff f g a b -> f a -> f a
addDiffableContainer = flip (foldl' go)
  where
    go x (Add n) = patchIn n x
    go x (Drop n) = patchOut n x
    go x (Shift d) = zipper (flip add) x d

-- | The difference for a container.  The only operations that you
-- should perform on this type are `add`, `foldDiff`, and `foldDiffM`.
-- I've intentionally made other operations difficult and inconvenient
-- to discourage other operations.  This enables us to swap out the
-- underlying implementation in the future for a more performant type.
type ContainerDiff f g value diff = S.Seq (Diff (g value) (f diff))

instance (Functor f, Additive diff) => Additive (ContainerDiff f g value diff) where
  zero = S.empty
  invert = S.reverse . fmap go where
    go (Add v) = Drop v
    go (Drop v) = Add v
    go (Shift v) = Shift $ fmap invert v
  plus = (<>)
  minus x y = x `plus` invert y


instance (Ord a) => DiffableContainer (M.Map a) ((,) a) where
  gains new = M.foldMapWithKey (curry pure) . M.difference new
  losses new = M.foldMapWithKey (curry pure) . flip M.difference new
  remained = M.intersectionWith (,)
  patchIn (k, v) = M.insert k v
  patchOut (k, _) = M.delete k
  zipper f = M.merge M.dropMissing M.dropMissing (M.zipWithMatched (const f))

instance (Ord a, Torsor value diff) => Torsor (M.Map a value) (ContainerDiff (M.Map a) ((,) a) value diff) where
  difference = differenceDiffableContainer
  add = addDiffableContainer

instance DiffableContainer IM.IntMap ((,) Int) where
  gains new = IM.foldMapWithKey (curry pure) . IM.difference new
  losses new = IM.foldMapWithKey (curry pure) . flip IM.difference new
  remained = IM.intersectionWith (,)
  patchIn (k, v) = IM.insert k v
  patchOut (k, _) = IM.delete k
  zipper f = IM.mergeWithKey (\_ a -> Just . f a) (const mempty) (const mempty)

instance (Torsor value diff) => Torsor (IM.IntMap value) (ContainerDiff IM.IntMap ((,) Int) value diff) where
  difference = differenceDiffableContainer
  add = addDiffableContainer

instance DiffableContainer S.Seq Identity where
  gains new old = foldMap (pure . Identity) $ S.drop (S.length old) new
  losses new old = foldMap (pure . Identity) $ S.drop (S.length new) old
  remained = S.zip
  patchIn v vs = vs S.|> runIdentity v
  patchOut _ vs = case S.viewr vs of
    S.EmptyR -> vs
    inner S.:> _ -> inner
  zipper = S.zipWith

instance (Torsor value diff) => Torsor (S.Seq value) (ContainerDiff S.Seq Identity value diff) where
  difference = differenceDiffableContainer
  add = addDiffableContainer

instance DiffableContainer Maybe Identity where
  gains (Just x) Nothing = pure $ Identity x
  gains _ _ = mempty
  losses Nothing (Just x) = pure $ Identity x
  losses _ _ = mempty
  remained (Just x) (Just y) = Just (x, y)
  remained _ _ = Nothing
  patchIn (Identity x) _ = Just x
  patchOut _ _ = Nothing
  zipper f a b = f <$> a <*> b

instance (Torsor value diff) => Torsor (Maybe value) (ContainerDiff Maybe Identity value diff) where
  difference = differenceDiffableContainer
  add = addDiffableContainer