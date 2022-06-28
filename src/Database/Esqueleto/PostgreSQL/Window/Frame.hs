{-# LANGUAGE OverloadedStrings #-}
module Database.Esqueleto.PostgreSQL.Window.Frame
    ( Frame
    , ToFrame(..)
    , renderFrame
    , range, rows, groups
    , excludeCurrentRow, excludeGroup, excludeTies, excludeNoOthers
    , between, unboundedFollowing, unboundedPreceeding, preceeding, following, currentRow
    )
    where

import Database.Esqueleto.Internal.Internal ( IdentInfo )
import Data.Int (Int64)
import Database.Esqueleto.Internal.PersistentImport (PersistValue(..))
import qualified Data.Text.Lazy.Builder as TLB

data Frame = Frame (Maybe FrameKind) FrameBody (Maybe FrameExclusion)

class ToFrame a where
    toFrame :: a -> Frame
instance ToFrame Frame where
    toFrame = id

renderFrame :: IdentInfo -> Frame -> (TLB.Builder, [PersistValue])
renderFrame info (Frame mKind frameBody mExclusion) =
    let (kind, kindVals) = maybe mempty (renderFrameKind info) mKind
        (exclusion, exclusionVals) = maybe mempty (renderFrameExclusion info) mExclusion
        (body, bodyVals) = renderFrameBody info frameBody
    in (" " <> kind <> body <> exclusion, kindVals <> bodyVals <> exclusionVals)


newtype FrameKind = FrameKind { unFrameKind :: (TLB.Builder, [PersistValue]) }

renderFrameKind :: IdentInfo -> FrameKind -> (TLB.Builder, [PersistValue])
renderFrameKind _ = unFrameKind

frameKind :: ToFrame frame => TLB.Builder -> frame -> Frame
frameKind tlb frame =
    let Frame _ b e = toFrame frame
    in Frame (Just (FrameKind (tlb <> " ", []))) b e

range :: ToFrame frame => frame -> Frame
range = frameKind "RANGE"

rows :: ToFrame frame => frame -> Frame
rows = frameKind "ROWS"

groups :: ToFrame frame => frame -> Frame
groups = frameKind "GROUPS"

newtype FrameExclusion = FrameExclusion { unFrameExclusion :: (TLB.Builder, [PersistValue]) }

renderFrameExclusion :: IdentInfo -> FrameExclusion -> (TLB.Builder, [PersistValue]) 
renderFrameExclusion _ = unFrameExclusion

frameExclusion :: ToFrame frame => TLB.Builder -> frame -> Frame
frameExclusion tlb frame =
    let Frame k b _ = toFrame frame
    in Frame k b (Just $ FrameExclusion (" EXCLUDE " <> tlb, []))

excludeCurrentRow :: ToFrame frame => frame -> Frame
excludeCurrentRow = frameExclusion "CURRENT ROW"

excludeGroup :: ToFrame frame => frame -> Frame
excludeGroup = frameExclusion "GROUP"

excludeTies :: ToFrame frame => frame -> Frame
excludeTies = frameExclusion "TIES"

excludeNoOthers :: ToFrame frame => frame -> Frame
excludeNoOthers = frameExclusion "NO OTHERS"

-- In order to prevent runtime errors we do some magic rewriting of queries that wouldn't be valid SQL.
-- In the case of an implicit frame end `following 10` would become BETWEEN 10 FOLLOWING AND CURRENT ROW
-- This is illegal so `following 10` instead becomes `BETWEEN CURRENT_ROW AND 10 FOLLOWING`
-- Additionally `BETWEEN` requires that the frame start be before the frame end.
-- To prevent this error the frame will be flipped automatically.
-- i.e. `between (following 10) (preceeding 10)` becomes `BETWEEEN 10 PRECEEDING AND 10 FOLLOWING`
-- therefore `between (following 10) (preceeding 10) === between (preceeding 10) (following 10)
data FrameBody
    = FrameStart FrameRange
    | FrameBetween FrameRange FrameRange

instance ToFrame FrameBody where
    toFrame b = Frame Nothing b Nothing

renderFrameBody :: IdentInfo -> FrameBody -> (TLB.Builder, [PersistValue])
renderFrameBody info (FrameStart (FrameRangeFollowing b)) = 
    renderFrameBody info (FrameBetween FrameRangeCurrentRow (FrameRangeFollowing b))
renderFrameBody info (FrameStart f) = 
    renderFrameRange info f
renderFrameBody info (FrameBetween startRange endRange) =
    if startRange > endRange then
        renderFrameBody info (FrameBetween endRange startRange)
    else
        let (b, v) = renderFrameRange info startRange
            (b', v') = renderFrameRange info endRange 
        in ("BETWEEN " <> b <> " AND " <> b', v <> v')

instance ToFrame FrameRange where
    toFrame r = Frame Nothing (FrameStart r) Nothing

renderFrameRange :: IdentInfo -> FrameRange -> (TLB.Builder, [PersistValue])
renderFrameRange _ FrameRangeCurrentRow = ("CURRENT ROW", [])
renderFrameRange _ (FrameRangePreceeding bounds) = renderBounds bounds <> (" PRECEEDING", [])
renderFrameRange _ (FrameRangeFollowing bounds) = renderBounds bounds <> (" FOLLOWING", [])

renderBounds :: FrameRangeBound -> (TLB.Builder, [PersistValue])
renderBounds (FrameRangeUnbounded) = ("UNBOUNDED", [])
renderBounds (FrameRangeBounded i) = ("?", [PersistInt64 i])

data FrameRange
    = FrameRangePreceeding FrameRangeBound
    | FrameRangeCurrentRow
    | FrameRangeFollowing FrameRangeBound
    deriving Eq

instance Ord FrameRange where
    FrameRangePreceeding b1 <= FrameRangePreceeding b2 = b1 <= b2
    FrameRangePreceeding _  <= FrameRangeCurrentRow    = True
    FrameRangePreceeding _  <= FrameRangeFollowing  _  = True
    FrameRangeCurrentRow    <= FrameRangePreceeding _  = False
    FrameRangeCurrentRow    <= FrameRangeCurrentRow    = True
    FrameRangeCurrentRow    <= FrameRangeFollowing  _  = True
    FrameRangeFollowing  _  <= FrameRangePreceeding _  = False
    FrameRangeFollowing  _  <= FrameRangeCurrentRow    = False
    FrameRangeFollowing  b1 <= FrameRangeFollowing  b2 = b1 <= b2

data FrameRangeBound
    = FrameRangeUnbounded
    | FrameRangeBounded Int64
    deriving Eq

instance Ord FrameRangeBound where
    FrameRangeUnbounded <= FrameRangeBounded _ = False
    FrameRangeUnbounded <= FrameRangeUnbounded = True
    FrameRangeBounded _ <= FrameRangeUnbounded = True
    FrameRangeBounded a <= FrameRangeBounded b = a <= b

between :: FrameRange -> FrameRange -> FrameBody
between = FrameBetween

unboundedPreceeding :: FrameRange
unboundedPreceeding = FrameRangePreceeding FrameRangeUnbounded

preceeding :: Int64 -> FrameRange
preceeding offset = FrameRangePreceeding (FrameRangeBounded offset)

following :: Int64 -> FrameRange
following offset = FrameRangeFollowing (FrameRangeBounded offset)

unboundedFollowing :: FrameRange
unboundedFollowing = FrameRangeFollowing FrameRangeUnbounded

currentRow :: FrameRange
currentRow = FrameRangeCurrentRow
