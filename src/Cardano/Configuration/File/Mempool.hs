-- | Options related to the mempool
module Cardano.Configuration.File.Mempool
  ( MempoolConfiguration (..)
  , finalizeMempool
  ) where

import Autodocodec
import Cardano.Configuration.Basic (diffTimeCodec, ErrorMessage)
import Data.Aeson (FromJSON, ToJSON)
import Data.Functor.Identity (Identity (..))
import Data.Time.Clock (DiffTime)
import Data.Word
import GHC.Generics (Generic)

-- | The mempool configuration. @mempoolCapacityOverride@ is optional by nature
-- (the node's default is "no override"), so it stays @Maybe@ in both forms. The
-- three timeouts, however, are resolved /together/: they must be either all set
-- or all unset, and all-unset takes a coupled default (see 'finalizeMempool'),
-- so they carry the @f@ parameter — @Maybe@ in the partial form, @Identity@ in
-- the resolved form. See "Cardano.Configuration.File" for the @f@ convention.
data MempoolConfiguration f = MempoolConfiguration
  { mempoolCapacityOverride :: Maybe Word64
  , mempoolTimeoutSoft :: f DiffTime
  , mempoolTimeoutHard :: f DiffTime
  , mempoolTimeoutCapacity :: f DiffTime
  }
  deriving Generic

deriving instance Show (MempoolConfiguration Maybe)
deriving instance Show (MempoolConfiguration Identity)

deriving via
  (Autodocodec (MempoolConfiguration Maybe))
  instance
    FromJSON (MempoolConfiguration Maybe)

deriving via
  (Autodocodec (MempoolConfiguration Maybe))
  instance
    ToJSON (MempoolConfiguration Maybe)

instance HasCodec (MempoolConfiguration Maybe) where
  codec =
    object "MempoolConfiguration" $
      MempoolConfiguration
        <$> optionalFieldWithDefaultWith
          "MempoolCapacityBytesOverride"
          mempoolCapacityOverrideCodec
          Nothing
          "Override for the maximum mempool size in bytes, or the string \"NoOverride\""
          .= mempoolCapacityOverride
        <*> optionalFieldWith "MempoolTimeoutSoft" diffTimeCodec "Soft mempool timeout, in seconds"
          .= mempoolTimeoutSoft
        <*> optionalFieldWith "MempoolTimeoutHard" diffTimeCodec "Hard mempool timeout, in seconds"
          .= mempoolTimeoutHard
        <*> optionalFieldWith "MempoolTimeoutCapacity" diffTimeCodec "Capacity mempool timeout, in seconds"
          .= mempoolTimeoutCapacity

-- | Resolve a partial mempool configuration. The three timeouts are coupled:
-- they must be either all set or all unset. All-unset takes the node's coupled
-- default of @(1, 1.5, 5)@ seconds (soft, hard, capacity); a mix of set and
-- unset is rejected. @mempoolCapacityOverride@ is independent and passes through.
finalizeMempool :: MempoolConfiguration Maybe -> Either ErrorMessage (MempoolConfiguration Identity)
finalizeMempool c =
  case (mempoolTimeoutSoft c, mempoolTimeoutHard c, mempoolTimeoutCapacity c) of
    (Just s, Just h, Just cap) ->
      Right (MempoolConfiguration (mempoolCapacityOverride c) (Identity s) (Identity h) (Identity cap))
    (Nothing, Nothing, Nothing) ->
      Right (MempoolConfiguration (mempoolCapacityOverride c) (Identity 1) (Identity 1.5) (Identity 5))
    _ ->
      Left "mempool timeouts (Soft, Hard, Capacity) must be all set or all unset"

-- | The mempool capacity override is either a byte count or the string
-- @"NoOverride"@ (which, like omitting the key, means \"use the default\").
mempoolCapacityOverrideCodec :: JSONCodec (Maybe Word64)
mempoolCapacityOverrideCodec =
  dimapCodec toOverride fromOverride $
    eitherCodec
      (codec @Word64)
      (literalTextCodec "NoOverride")
 where
  toOverride = either Just (const Nothing)
  fromOverride (Just c) = Left c
  fromOverride Nothing = Right "NoOverride"
