{-# OPTIONS_GHC -Wno-orphans #-}

-- | An @autodocodec@ codec for the Dijkstra-era genesis, decoding the genesis
-- JSON into the ledger's 'DijkstraGenesis' type (rather than reusing the
-- ledger's @aeson@ instances). This is the first era ported into this library;
-- the same shape will be followed for the other eras so that, eventually, this
-- is the only library that resolves genesis JSON.
--
-- The on-the-wire keys match the ledger's @FromJSON@/@ToJSON@ instances for
-- @UpgradeDijkstraPParams@ (a 'DijkstraGenesis' is a newtype around it, so its
-- JSON is the flat object of these keys).
module Cardano.Configuration.Genesis.Dijkstra (
  dijkstraGenesisCodec,
  nonZeroCodec,
  positiveIntervalCodec,
) where

import Autodocodec
import Cardano.Ledger.BaseTypes (HasZero, NonZero, PositiveInterval, nonZero, unNonZero)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis (..))
import Cardano.Ledger.Dijkstra.PParams (UpgradeDijkstraPParams (..))
import Data.Word (Word32)

-- | A codec for @'NonZero' a@: (de)serialise the underlying value, rejecting a
-- zero on the way in, exactly as the ledger's @FromJSON (NonZero a)@ does.
nonZeroCodec :: HasZero a => JSONCodec a -> JSONCodec (NonZero a)
nonZeroCodec inner =
  bimapCodec
    (maybe (Left "expected a non-zero value") Right . nonZero)
    unNonZero
    inner

-- | A codec for 'PositiveInterval' (a @BoundedRatio@). Its on-the-wire form is
-- dual — a plain JSON number when it has a terminating decimal, otherwise a
-- @{ "numerator", "denominator" }@ object — and it is bounds-checked on decode,
-- so we defer to the ledger's @aeson@ instances for the leaf value rather than
-- re-deriving that representation here.
positiveIntervalCodec :: JSONCodec PositiveInterval
positiveIntervalCodec = codecViaAeson "PositiveInterval"

-- | The codec for the Dijkstra genesis. A 'DijkstraGenesis' is a newtype around
-- @'UpgradeDijkstraPParams' 'Identity'@, whose JSON is a flat object of the four
-- reference-script parameters introduced in the Dijkstra era.
dijkstraGenesisCodec :: JSONCodec DijkstraGenesis
dijkstraGenesisCodec =
  object "DijkstraGenesis" $
    mk
      <$> requiredFieldWith
        "maxRefScriptSizePerBlock"
        (codec @Word32)
        "Maximum total size of reference scripts per block, in bytes"
        .= field udppMaxRefScriptSizePerBlock
      <*> requiredFieldWith
        "maxRefScriptSizePerTx"
        (codec @Word32)
        "Maximum total size of reference scripts per transaction, in bytes"
        .= field udppMaxRefScriptSizePerTx
      <*> requiredFieldWith
        "refScriptCostStride"
        (nonZeroCodec (codec @Word32))
        "Size, in bytes, of each reference-script pricing tier"
        .= field udppRefScriptCostStride
      <*> requiredFieldWith
        "refScriptCostMultiplier"
        positiveIntervalCodec
        "Multiplier applied to the reference-script cost of each successive tier"
        .= field udppRefScriptCostMultiplier
  where
    field f = f . dgUpgradePParams
    mk a b c d = DijkstraGenesis (UpgradeDijkstraPParams a b c d)

instance HasCodec DijkstraGenesis where
  codec = dijkstraGenesisCodec
