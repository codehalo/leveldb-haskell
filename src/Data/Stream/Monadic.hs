{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE ExistentialQuantification #-}

-- |
-- Module      : Data.Stream.Monadic
-- Copyright   : (c) 2014 Kim Altintop
-- License     : BSD3
-- Maintainer  : kim.altintop@gmail.com
-- Stability   : experimental
-- Portability : non-portable
--
-- (Mostly mechanical) adaptation of the
-- <http://hackage.haskell.org/package/stream-fusion/docs/Data-Stream.html Data.Stream>
-- module from the
-- <http://hackage.haskell.org/package/stream-fusion stream-fusion> package to a
-- monadic 'Stream' datatype similar to the one
-- <https://www.fpcomplete.com/blog/2014/08/conduit-stream-fusion proposed> by
-- Michael Snoyman for the <http://hackage.haskell.org/package/conduit conduit>
-- package.
--
-- The intention here is to provide a high-level, "Data.List"-like interface to
-- "Database.LevelDB.Iterator"s with predictable space and time complexity (see
-- "Database.LevelDB.Streaming"), and without introducing a dependency eg. on
-- one of the streaming libraries (all relevant datatypes are fully exported,
-- though, so it should be straightforward to write wrappers for your favourite
-- streaming library).
--
-- Fusion and inlining rules and strictness annotations have been put in place
-- faithfully, and may need further profiling. Also, some functions (from
-- "Data.List") have been omitted for various reasons. Missing functions may be
-- added upon <https://github.com/kim/leveldb-haskell/pulls request>.

module Data.Stream.Monadic
    ( Step   (..)
    , Stream (..)

    -- * Conversion with lists
    , toList
    , fromList

    -- * Basic functions
    , append
    , cons
    , snoc
    , head
    , last
    , tail
    , init
    , null
    , length

    -- * Transformations
    , map
    , mapM
    , mapM_
    , intersperse

    -- * Folds
    , foldl
    , foldl'
    -- , foldl1
    -- , foldl1'
    , foldr
    -- , foldr1
    , foldMap
    , foldM
    , foldM_

    -- * Special folds
    , concat
    , concatMap
    , and
    , or
    , any
    , all
    , sum
    , product
    --, maximum
    --, minimum

    -- , scanl
    -- , scanl1

    -- * Infinite streams
    , iterate
    , repeat
    , replicate
    , cycle

    -- * Unfolding
    , unfoldr
    , unfoldrM

    -- , isPrefixOf

    -- * Searching streams
    -- , elem
    -- , lookup

    , find
    , filter

    -- , index
    -- , findIndex
    -- , elemIndex
    -- , elemIndices
    -- , findIndices

    -- * Substreams
    , take
    , drop
    -- , splitAt
    , takeWhile
    , dropWhile

    -- * Zipping and unzipping
    , zip
    -- , zip3
    -- , zip4
    , zipWith
    -- , zipWith3
    -- , zipWith4
    , unzip

    -- , insertBy
    -- , maximumBy
    -- , minimumBy

    -- , genericLength
    -- , genericTake
    -- , genericDrop
    -- , genericIndex
    -- , genericSplitAt

    -- , enumFromToInt
    -- , enumFromToChar
    -- , enumDeltaInteger
    )
where

import Control.Applicative
import Control.Monad       (Monad (..), void, (=<<), (>=>))
import Data.Monoid

import Prelude (Bool (..), Either (..), Eq (..), Functor (..), Int, Maybe (..),
                Num (..), Ord (..), error, otherwise, ($), (&&), (.), (||))


data Step   a  s
   = Yield  a !s
   | Skip  !s
   | Done

data Stream m a = forall s. Stream (s -> m (Step a s)) (m s)

instance Monad m => Functor (Stream m) where
    fmap = map


toList :: (Functor m, Monad m) => Stream m a -> m [a]
toList (Stream next s0) = unfold =<< s0
  where
    unfold !s = do
        step <- next s
        case step of
            Done       -> return []
            Skip    s' -> unfold s'
            Yield x s' -> (x :) <$> unfold s'
{-# INLINE [0] toList #-}

fromList :: Monad m => [a] -> Stream m a
fromList xs = Stream next (return xs)
  where
    {-# INLINE next #-}
    next []      = return Done
    next (x:xs') = return $ Yield x xs'
{-# INLINE [0] fromList #-}
{-# RULES
"Stream fromList/toList fusion" forall s.
    fmap fromList (toList s) = return s
  #-}

append :: (Functor m, Monad m) => Stream m a -> Stream m a -> Stream m a
append (Stream next0 s0) (Stream next1 s1) = Stream next (Left <$> s0)
  where
    {-# INLINE next #-}
    next (Left s) = do
        step <- next0 s
        case step of
            Done       -> Skip . Right <$> s1
            Skip    s' -> return $ Skip    (Left s')
            Yield x s' -> return $ Yield x (Left s')

    next (Right s) = do
        step <- next1 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip    (Right s')
            Yield x s' -> Yield x (Right s')
{-# INLINE [0] append #-}

cons :: (Functor m, Monad m) => a -> Stream m a -> Stream m a
cons w (Stream next0 s0) = Stream next ((,) S2 <$> s0)
  where
    {-# INLINE next #-}
    next (S2, s) = return $ Yield w (S1, s)
    next (S1, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip    (S1, s')
            Yield x s' -> Yield x (S1, s')
{-# INLINE [0] cons #-}

snoc :: (Functor m, Monad m) => Stream m a -> a -> Stream m a
snoc (Stream next0 s0) y = Stream next (Just <$> s0)
  where
    {-# INLINE next #-}
    next Nothing  = return Done
    next (Just s) = do
        step <- next0 s
        return $ case step of
            Done       -> Yield y Nothing
            Skip    s' -> Skip    (Just s')
            Yield x s' -> Yield x (Just s')
{-# INLINE [0] snoc #-}

-- | Unlike 'Data.List.head', this function does not diverge if the 'Stream' is
-- empty. Instead, 'Nothing' is returned.
head :: Monad m => Stream m a -> m (Maybe a)
head (Stream next s0) = loop =<< s0
  where
    loop !s = do
        step <- next s
        case step of
            Yield x _  -> return $ Just x
            Skip    s' -> loop s'
            Done       -> return Nothing
{-# INLINE [0] head #-}

-- | Unlike 'Data.List.last', this function does not diverge if the 'Stream' is
-- empty. Instead, 'Nothing' is returned.
last :: Monad m => Stream m a -> m (Maybe a)
last (Stream next s0) = loop =<< s0
  where
    loop !s = do
        step <- next s
        case step of
            Done       -> return Nothing
            Skip    s' -> loop s'
            Yield x s' -> loop' x s'
    loop' x !s = do
        step <- next s
        case step of
            Done        -> return $ Just x
            Skip     s' -> loop' x s'
            Yield x' s' -> loop' x' s'
{-# INLINE [0] last #-}

data Switch = S1 | S2

-- | Unlike 'Data.List.tail', this function does not diverge if the 'Stream' is
-- empty. Instead, it is the identity in this case.
tail :: (Functor m, Monad m) => Stream m a -> Stream m a
tail (Stream next0 s0) = Stream next ((,) S1 <$> s0)
  where
    {-# INLINE next #-}
    next (S1, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip (S1, s')
            Yield _ s' -> Skip (S2, s')

    next (S2, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip (S2, s')
            Yield x s' -> Yield x (S2, s')
{-# INLINE [0] tail #-}

-- | Unlike 'Data.List.init', this function does not diverge if the 'Stream' is
-- empty. Instead, it is the identity in this case.
init :: (Functor m, Monad m) => Stream m a -> Stream m a
init (Stream next0 s0) = Stream next ((,) Nothing <$> s0)
  where
    {-# INLINE next #-}
    next (Nothing, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip (Nothing, s')
            Yield x s' -> Skip (Just x , s')

    next (Just x, s) = do
        step <- next0 s
        return $ case step of
            Done        -> Done
            Skip     s' -> Skip    (Just x , s')
            Yield x' s' -> Yield x (Just x', s')
{-# INLINE [0] init #-}

null :: Monad m => Stream m a -> m Bool
null (Stream next s0) = loop =<< s0
  where
    loop !s = do
        step <- next s
        case step of
            Done       -> return True
            Yield _ _  -> return False
            Skip    s' -> loop s'
{-# INLINE [0] null #-}

length :: Monad m => Stream m a -> m Int
length (Stream next s0) = loop 0 =<< s0
  where
    loop !z !s = do
        step <- next s
        case step of
            Done       -> return z
            Skip    s' -> loop   z    s'
            Yield _ s' -> loop  (z+1) s'
{-# INLINE [0] length #-}

find :: Monad m => (a -> Bool) -> Stream m a -> m (Maybe a)
find p = head . filter p
{-# INLINE [0] find #-}

filter :: Monad m => (a -> Bool) -> Stream m a -> Stream m a
filter p (Stream next0 s0) = Stream next s0
  where
    {-# INLINE next #-}
    next !s = do
        step <- next0 s
        return $ case step of
            Done                   -> Done
            Skip    s'             -> Skip    s'
            Yield x s' | p x       -> Yield x s'
                       | otherwise -> Skip    s'
{-# INLINE [0] filter #-}
{-# RULES
"Stream filter/filter fusion" forall p q s.
    filter p (filter q s) = filter (\ x -> q x && p x) s
  #-}

map :: Monad m => (a -> b) -> Stream m a -> Stream m b
map f (Stream next0 s0) = Stream next s0
  where
    {-# INLINE next #-}
    next !s = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip        s'
            Yield x s' -> Yield (f x) s'
{-# INLINE [0] map #-}
{-# RULES
"Stream map/map fusion" forall f g s.
    map f (map g s) = map (f . g) s
  #-}

mapM :: (Functor m, Monad m) => (a -> m b) -> Stream m a -> Stream m b
mapM f (Stream next0 s0) = Stream next s0
  where
    {-# INLINE next #-}
    next !s = do
        step <- next0 s
        case step of
            Done       -> return Done
            Skip    s' -> return $ Skip s'
            Yield x s' -> (`Yield` s') <$> f x
{-# INLINE [0] mapM #-}
{-# RULES
"Stream mapM/mapM fusion" forall f g s.
    mapM f (mapM g s) = mapM (g >=> f) s

"Stream map/mapM fusion" forall f g s.
    map f (mapM g s)  = mapM (fmap f . g) s

"Stream mapM/map fusion" forall f g s.
    mapM f (map g s)  = mapM (f . g) s
  #-}

mapM_ :: (Functor m, Monad m) => (a -> m b) -> Stream m a -> Stream m ()
mapM_ f s = Stream go (return ())
  where
    {-# INLINE go #-}
    go _ = foldM_ (\ _ -> void . f) () s >> return Done
{-# INLINE [0] mapM_ #-}
{-# RULES
"Stream mapM_/mapM fusion" forall f g s.
    mapM_ f (mapM g s) = mapM_ (g >=> f) s

"Stream mapM_/map fusion" forall f g s.
    mapM_ f (map g s)  = mapM_ (f . g) s
  #-}

intersperse :: (Functor m, Monad m) => a -> Stream m a -> Stream m a
intersperse sep (Stream next0 s0) = Stream next ((,,) Nothing S1 <$> s0)
  where
    {-# INLINE next #-}
    next (Nothing, S1, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip (Nothing, S1, s')
            Yield x s' -> Skip (Just x , S1, s')

    next (Just x, S1, s)  = return $ Yield x (Nothing, S2, s)

    next (Nothing, S2, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip      (Nothing, S2, s')
            Yield x s' -> Yield sep (Just x , S1, s')

    next (Just _, S2, _)  = error "Data.Stream.Monadic.intersperse: impossible"
{-# INLINE [0] intersperse #-}

foldMap :: (Monoid m, Functor n, Monad n) => (a -> m) -> Stream n a -> n m
foldMap f (Stream next s0) = loop mempty =<< s0
  where
    loop z !s = do
        step <- next s
        case step of
            Done       -> return z
            Skip    s' -> loop z s'
            Yield x s' -> loop (z <> f x) s'
{-# INLINE [0] foldMap #-}
{-# RULES
"Stream foldMap/map fusion" forall f g s.
    foldMap f (map g s)  = foldMap (f . g) s

"Stream foldMap/mapM fusion" forall f g s.
    foldMap f (mapM g s) = foldM (\ z' -> fmap ((z' <>) . f) . g) mempty s
  #-}

-- | Left-associative fold.
--
-- Note that the /direction/ of the traversal is not defined here.
foldl :: Monad m => (b -> a -> b) -> b -> Stream m a -> m b
foldl f z0 (Stream next s0) = loop z0 =<< s0
  where
    loop z !s = do
        step <- next s
        case step of
            Done       -> return z
            Skip    s' -> loop z s'
            Yield x s' -> loop (f z x) s'
{-# INLINE [0] foldl #-}
{-# RULES
"Stream foldl/map fusion" forall f g z s.
    foldl f z (map g s)  = foldl (\ z' -> f z' . g) z s

"Stream foldl/mapM fusion" forall f g z s.
    foldl f z (mapM g s) = foldM (\ z' -> fmap (f z') . g) z s
  #-}

-- | Left-associative fold with strict accumulator.
--
-- Note that the /direction/ of the traversal is not defined here.
foldl' :: Monad m => (b -> a -> b) -> b -> Stream m a -> m b
foldl' f z0 (Stream next s0) = loop z0 =<< s0
  where
    loop !z !s = do
        step <- next s
        case step of
            Done       -> return z
            Skip    s' -> loop z s'
            Yield x s' -> loop (f z x) s'
{-# INLINE [0] foldl' #-}
{-# RULES
"Stream foldl'/map fusion" forall f g z s.
    foldl' f z (map g s)  = foldl' (\ z' -> f z' . g) z s

"Stream foldl'/mapM fusion" forall f g z s.
    foldl' f z (mapM g s) = foldM  (\ z' -> fmap (f z') . g) z s
  #-}

-- | Right-associative fold.
--
-- Note that the /direction/ of the traversal is not defined here.
foldr :: (Functor m, Monad m) => (a -> b -> b) -> b -> Stream m a -> m b
foldr f z (Stream next s0) = loop =<< s0
  where
    loop !s = do
        step <- next s
        case step of
            Done       -> return z
            Skip    s' -> loop s'
            Yield x s' -> f x <$> loop s'
{-# INLINE [0] foldr #-}
{-# RULES
"Stream foldr/map fusion" forall f g z s.
    foldr f z (map g s)  = foldr (f . g) z s

"Stream foldr/mapM fusion" forall f g z s.
    foldr f z (mapM g s) = foldM (\ z' -> fmap (`f` z') . g) z s
  #-}

foldM :: Monad m => (b -> a -> m b) -> b -> Stream m a -> m b
foldM f z0 (Stream next s0) = loop z0 =<< s0
  where
    loop z !s = do
        step <- next s
        case step of
            Done       -> return z
            Skip    s' -> loop z s'
            Yield x s' -> f z x >>= (`loop` s')
{-# INLINE [0] foldM #-}
{-# RULES
"Stream foldM/map fusion" forall f g z s.
    foldM f z (map g s)  = foldM (\ z' -> f z' . g) z s

"Stream foldM/mapM fusion" forall f g z s.
    foldM f z (mapM g s) = foldM (\ z' -> g >=> f z') z s
  #-}

foldM_ :: Monad m => (b -> a -> m b) -> b -> Stream m a -> m ()
foldM_ f z s = foldM f z s >> return ()
{-# INLINE foldM_ #-}

concat :: (Functor m, Monad m) => Stream m [a] -> m [a]
concat (Stream next s0) = to =<< s0
  where
    to !s = do
        step <- next s
        case step of
            Done        -> return []
            Skip     s' -> to    s'
            Yield xs s' -> go xs s'

    go []     !s = to s
    go (x:xs) !s = (x :) <$> go xs s
{-# INLINE [0] concat #-}

concatMap :: (Functor m, Monad m) => (a -> Stream m b) -> Stream m a -> Stream m b
concatMap f (Stream next0 s0) = Stream next ((,) Nothing <$> s0)
  where
    {-# INLINE next #-}
    next (Nothing, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip (Nothing   , s')
            Yield x s' -> Skip (Just (f x), s')

    next (Just (Stream g t), s) = do
        step <- g =<< t
        return $ case step of
            Done       -> Skip    (Nothing                    , s)
            Skip    t' -> Skip    (Just (Stream g (return t')), s)
            Yield x t' -> Yield x (Just (Stream g (return t')), s)
{-# INLINE [0] concatMap #-}
{-# RULES
"Stream concatMap/map fusion" forall f g s.
    concatMap f (map g s) = concatMap (f . g) s
  #-}

and :: (Functor m, Monad m) => Stream m Bool -> m Bool
and = foldr (&&) True
{-# INLINE and #-}

or :: (Functor m, Monad m) => Stream m Bool -> m Bool
or = foldr (||) False
{-# INLINE or #-}

any :: Monad m => (a -> Bool) -> Stream m a -> m Bool
any p (Stream next s0) = loop =<< s0
  where
    loop !s = do
        step <- next s
        case step of
            Done                   -> return False
            Skip    s'             -> loop s'
            Yield x s' | p x       -> return True
                       | otherwise -> loop s'
{-# INLINE [0] any #-}

all :: Monad m => (a -> Bool) -> Stream m a -> m Bool
all p (Stream next s0) = loop =<< s0
  where
    loop !s = do
        step <- next s
        case step of
            Done                   -> return True
            Skip    s'             -> loop s'
            Yield x s' | p x       -> loop s'
                       | otherwise -> return False
{-# INLINE [0] all #-}

sum :: (Num a, Monad m) => Stream m a -> m a
sum (Stream next s0) = loop 0 =<< s0
  where
    loop !a !s = do
        step <- next s
        case step of
            Done       -> return a
            Skip    s' -> loop   a      s'
            Yield x s' -> loop  (a + x) s'
{-# INLINE [0] sum #-}

product :: (Num a, Monad m) => Stream m a -> m a
product (Stream next s0) = loop 1 =<< s0
  where
    loop !a !s = do
        step <- next s
        case step of
            Done       -> return a
            Skip    s' -> loop   a      s'
            Yield x s' -> loop  (a * x) s'
{-# INLINE [0] product #-}

iterate :: Monad m => (a -> a) -> a -> Stream m a
iterate f x0 = Stream next (return x0)
  where
    {-# INLINE next #-}
    next x = return $ Yield x (f x)
{-# INLINE [0] iterate #-}

repeat :: Monad m => a -> Stream m a
repeat x = Stream next (return ())
  where
    {-# INLINE next #-}
    next _ = return $ Yield x ()
{-# INLINE [0] repeat #-}
{-# RULES
"map/repeat" forall f x.
    map f (repeat x) = repeat (f x)
  #-}

replicate :: Monad m => Int -> a -> Stream m a
replicate n x = Stream next (return n)
  where
    {-# INLINE next #-}
    next !i | i <= 0    = return Done
            | otherwise = return $ Yield x (i-1)
{-# INLINE [0] replicate #-}
{-# RULES
"map/replicate" forall f n x.
    map f (replicate n x) = replicate n (f x)
  #-}

-- | Unlike 'Data.List.cycle', this function does not diverge if the 'Stream' is
-- empty. Instead, it is the identity in this case.
cycle :: (Functor m, Monad m) => Stream m a -> Stream m a
cycle (Stream next0 s0) = Stream next ((,) S1 <$> s0)
  where
    {-# INLINE next #-}
    next (S1, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done -- error?
            Skip    s' -> Skip    (S1, s')
            Yield x s' -> Yield x (S2, s')

    next (S2, s) = do
        step <- next0 s
        case step of
            Done       -> Skip . (,) S2 <$> s0
            Skip    s' -> return $ Skip    (S2, s')
            Yield x s' -> return $ Yield x (S2, s')
{-# INLINE [0] cycle #-}

unfoldr :: Monad m => (b -> Maybe (a, b)) -> b -> Stream m a
unfoldr f s0 = Stream next (return s0)
  where
    {-# INLINE next #-}
    next s = return $ case f s of
        Nothing      -> Done
        Just (w, s') -> Yield w s'
{-# INLINE [0] unfoldr #-}

-- | Build a stream from a monadic seed (or state function).
unfoldrM :: (Functor m, Monad m) => (b -> Maybe (a, m b)) -> m b -> Stream m a
unfoldrM f = Stream next
  where
    {-# INLINE next #-}
    next s = case f s of
        Nothing      -> return Done
        Just (w, s') -> Yield w <$> s'
{-# INLINE [0] unfoldrM #-}

take :: (Functor m, Monad m) => Int -> Stream m a -> Stream m a
take n0 (Stream next0 s0) = Stream next ((,) n0 <$> s0)
  where
    {-# INLINE next #-}
    next (!n, s)
      | n <= 0    = return Done
      | otherwise = do
          step <- next0 s
          return $ case step of
              Done       -> Done
              Skip    s' -> Skip    (n  , s')
              Yield x s' -> Yield x (n-1, s')
{-# INLINE [0] take #-}

drop :: (Functor m, Monad m) => Int -> Stream m a -> Stream m a
drop n0 (Stream next0 s0) = Stream next ((,) (Just (max 0 n0)) <$> s0)
  where
    {-# INLINE next #-}
    next (Just !n, s)
      | n == 0    = return $ Skip (Nothing, s)
      | otherwise = do
          step <- next0 s
          return $ case step of
              Done       -> Done
              Skip    s' -> Skip (Just  n   , s')
              Yield _ s' -> Skip (Just (n-1), s')
    next (Nothing, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip    (Nothing, s')
            Yield x s' -> Yield x (Nothing, s')
{-# INLINE [0] drop #-}

takeWhile :: Monad m => (a -> Bool) -> Stream m a -> Stream m a
takeWhile p (Stream next0 s0) = Stream next s0
  where
    {-# INLINE next #-}
    next !s = do
        step <- next0 s
        return $ case step of
            Done                   -> Done
            Skip    s'             -> Skip    s'
            Yield x s' | p x       -> Yield x s'
                       | otherwise -> Done
{-# INLINE [0] takeWhile #-}

dropWhile :: (Functor m, Monad m) => (a -> Bool) -> Stream m a -> Stream m a
dropWhile p (Stream next0 s0) = Stream next ((,) S1 <$> s0)
  where
    {-# INLINE next #-}
    next (S1, s) = do
        step <- next0 s
        return $ case step of
            Done                   -> Done
            Skip    s'             -> Skip    (S1, s')
            Yield x s' | p x       -> Skip    (S1, s')
                       | otherwise -> Yield x (S2, s')
    next (S2, s) = do
        step <- next0 s
        return $ case step of
            Done       -> Done
            Skip    s' -> Skip    (S2, s')
            Yield x s' -> Yield x (S2, s')
{-# INLINE [0] dropWhile #-}

zip :: (Functor m, Applicative m, Monad m)
    => Stream m a
    -> Stream m b
    -> Stream m (a, b)
zip = zipWith (,)
{-# INLINE [0] zip #-}

zipWith :: (Functor m, Applicative m, Monad m)
        => (a -> b -> c)
        -> Stream m a
        -> Stream m b
        -> Stream m c
zipWith f (Stream nexta sa0) (Stream nextb sb0) =
    Stream next ((,,) Nothing <$> sa0 <*> sb0)
  where
    {-# INLINE next #-}
    next (Nothing, sa, sb) = do
        step <- nexta sa
        return $ case step of
            Done        -> Done
            Skip    sa' -> Skip (Nothing, sa', sb)
            Yield a sa' -> Skip (Just a , sa', sb)

    next (Just a, sa', sb) = do
        step <- nextb sb
        return $ case step of
            Done        -> Done
            Skip    sb' -> Skip          (Just a, sa', sb')
            Yield b sb' -> Yield (f a b) (Nothing, sa', sb')
{-# INLINE [0] zipWith #-}

unzip :: (Functor m, Monad m) => Stream m (a, b) -> m ([a], [b])
unzip = foldr (\(a,b) ~(as, bs) -> (a:as, b:bs)) ([], [])
{-# INLINE [0] unzip #-}
{-# RULES
"zip/unzip fusion" forall a b.
    unzip (zip a b) = (,) <$> toList a <*> toList b
  #-}
