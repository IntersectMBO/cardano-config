{-# OPTIONS_GHC -Wno-orphans #-}

-- | A by-hand @autodocodec@ codec for the Shelley-era genesis, decoding the
-- genesis JSON into the ledger's 'ShelleyGenesis' type. The on-the-wire keys and
-- value encodings match the ledger's @FromJSON@/@ToJSON@ instances exactly,
-- including the \"legacy\" protocol-parameters encoding used in genesis files.
--
-- The deeply-nested 'StakePoolParams' record (and the 'ShelleyExtraConfig'
-- injection data) are, for now, decoded via the ledger's aeson instances; the
-- rest is fully field-level. These two are not exercised by the mainnet genesis
-- and are the remaining types to hand-roll.
module Cardano.Configuration.Genesis.Shelley
  ( shelleyGenesisCodec
  , shelleyPParamsCodec
  ) where

import Autodocodec
import Cardano.Configuration.Genesis.Ledger
import Cardano.Crypto.Hash (hashFromTextAsHex, hashToTextAsHex)
import Cardano.Ledger.Address (Addr, decodeAddr, serialiseAddr)
import Cardano.Ledger.BaseTypes
  ( maybeToStrictMaybe
  , strictMaybeToMaybe
  )
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Core (PParams (..))
import Cardano.Ledger.Hashes (GenDelegPair (..), KeyHash (..))
import Cardano.Ledger.Shelley (ShelleyEra)
import Cardano.Ledger.Shelley.Genesis
  ( NominalDiffTimeMicro (..)
  , ShelleyExtraConfig
  , ShelleyGenesis (..)
  , ShelleyGenesisStaking (..)
  , emptyGenesisStaking
  )
import Cardano.Ledger.Shelley.PParams (ShelleyPParams (..))
import qualified Data.ByteString.Base16 as B16
import qualified Data.ListMap as LM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime)
import Data.Word (Word16, Word32, Word64)

instance HasCodec ShelleyGenesis where
  codec = shelleyGenesisCodec

-- | The codec for the Shelley genesis (16 documented keys).
shelleyGenesisCodec :: JSONCodec ShelleyGenesis
shelleyGenesisCodec =
  object "ShelleyGenesis" $
    ShelleyGenesis
      <$> requiredFieldWith "systemStart" (codec @UTCTime) "System start time"
        .= sgSystemStart
      <*> requiredFieldWith "networkMagic" (codec @Word32) "Network magic"
        .= sgNetworkMagic
      <*> requiredFieldWith "networkId" networkCodec "Network id"
        .= sgNetworkId
      <*> requiredFieldWith
        "activeSlotsCoeff"
        (boundedRationalCodec "activeSlotsCoeff")
        "Active slot coefficient"
        .= sgActiveSlotsCoeff
      <*> requiredFieldWith "securityParam" (nonZeroCodec (codec @Word64)) "Security parameter k"
        .= sgSecurityParam
      <*> requiredFieldWith "epochLength" epochSizeCodec "Epoch length in slots"
        .= sgEpochLength
      <*> requiredFieldWith "slotsPerKESPeriod" (codec @Word64) "Slots per KES period"
        .= sgSlotsPerKESPeriod
      <*> requiredFieldWith "maxKESEvolutions" (codec @Word64) "Maximum KES evolutions"
        .= sgMaxKESEvolutions
      <*> requiredFieldWith "slotLength" slotLengthCodec "Slot length in seconds"
        .= sgSlotLength
      <*> requiredFieldWith "updateQuorum" (codec @Word64) "Update quorum"
        .= sgUpdateQuorum
      <*> requiredFieldWith "maxLovelaceSupply" (codec @Word64) "Maximum lovelace supply"
        .= sgMaxLovelaceSupply
      <*> requiredFieldWith "protocolParams" shelleyPParamsCodec "Initial protocol parameters"
        .= sgProtocolParams
      <*> requiredFieldWith "genDelegs" genDelegsCodec "Genesis key delegations"
        .= sgGenDelegs
      <*> requiredFieldWith "initialFunds" initialFundsCodec "Initial UTxO funds"
        .= sgInitialFunds
      <*> optionalFieldWithDefaultWith "staking" stakingCodec emptyGenesisStaking "Initial stake distribution"
        .= sgStaking
      <*> extraConfigField
        .= sgExtraConfig
 where
  extraConfigField =
    dimapCodec maybeToStrictMaybe strictMaybeToMaybe $
      optionalFieldWith "extraConfig" extraConfigCodec "Extra streaming-injection configuration"

-- | The genesis (\"legacy\") encoding of the Shelley protocol parameters.
shelleyPParamsCodec :: JSONCodec (PParams ShelleyEra)
shelleyPParamsCodec =
  object "ShelleyPParams" $
    mk
      <$> requiredFieldWith "minFeeA" coinPerByteCodec "The constant factor for the minimum fee calculation"
        .= field sppTxFeePerByte
      <*> requiredFieldWith "minFeeB" compactCoinCodec "The linear factor for the minimum fee calculation"
        .= field sppTxFeeFixed
      <*> requiredFieldWith "maxBlockBodySize" (codec @Word32) "Maximum block body size"
        .= field sppMaxBBSize
      <*> requiredFieldWith "maxTxSize" (codec @Word32) "Maximum transaction size"
        .= field sppMaxTxSize
      <*> requiredFieldWith "maxBlockHeaderSize" (codec @Word16) "Maximum block header size"
        .= field sppMaxBHSize
      <*> requiredFieldWith "keyDeposit" compactCoinCodec "The amount of a key registration deposit"
        .= field sppKeyDeposit
      <*> requiredFieldWith "poolDeposit" compactCoinCodec "The amount of a pool registration deposit"
        .= field sppPoolDeposit
      <*> requiredFieldWith "eMax" epochIntervalCodec "Epoch bound on pool retirement"
        .= field sppEMax
      <*> requiredFieldWith "nOpt" (codec @Word16) "Desired number of pools"
        .= field sppNOpt
      <*> requiredFieldWith "a0" (boundedRationalCodec "a0") "Pool influence"
        .= field sppA0
      <*> requiredFieldWith "rho" (boundedRationalCodec "rho") "Monetary expansion"
        .= field sppRho
      <*> requiredFieldWith "tau" (boundedRationalCodec "tau") "Treasury expansion"
        .= field sppTau
      <*> requiredFieldWith
        "decentralisationParam"
        (boundedRationalCodec "decentralisationParam")
        "Decentralisation parameter"
        .= field sppD
      <*> requiredFieldWith "extraEntropy" nonceCodec "Extra entropy"
        .= field sppExtraEntropy
      <*> requiredFieldWith "protocolVersion" protVerCodec "Protocol version"
        .= field sppProtocolVersion
      <*> optionalFieldWithDefaultWith "minUTxOValue" compactCoinCodec mempty "Minimum UTxO value"
        .= field sppMinUTxOValue
      <*> optionalFieldWithDefaultWith "minPoolCost" compactCoinCodec mempty "Minimum pool cost"
        .= field sppMinPoolCost
 where
  field f = f . unwrap
  unwrap (PParams sp) = sp
  mk a b c d e f g h i j k l m n o p q =
    PParams (ShelleyPParams a b c d e f g h i j k l m n o p q)

-- | @slotLength@ is a 'NominalDiffTimeMicro' (a JSON number in seconds).
slotLengthCodec :: JSONCodec NominalDiffTimeMicro
slotLengthCodec = nominalDiffTimeMicroCodec NominalDiffTimeMicro unNominalDiffTimeMicro
 where
  unNominalDiffTimeMicro (NominalDiffTimeMicro m) = m

-- | @genDelegs@ is a JSON object keyed by genesis-key hash.
genDelegsCodec :: JSONCodec (Map (KeyHash r) GenDelegPair)
genDelegsCodec = mapAsObjectCodec keyHashToText keyHashFromText genDelegPairCodec

-- | A genesis delegation pair: @{ "delegate": <hex>, "vrf": <hex> }@.
genDelegPairCodec :: JSONCodec GenDelegPair
genDelegPairCodec =
  object "GenDelegPair" $
    GenDelegPair
      <$> requiredFieldWith "delegate" keyHashCodec "Delegate key hash" .= genDelegKeyHash
      <*> requiredFieldWith "vrf" vrfVerKeyHashCodec "Delegate VRF key hash" .= genDelegVrfHash

-- | @initialFunds@ is a JSON object keyed by (hex-encoded) address.
initialFundsCodec :: JSONCodec (LM.ListMap Addr Coin)
initialFundsCodec =
  dimapCodec
    (LM.fromList . Map.toList)
    (Map.fromList . LM.toList)
    (mapAsObjectCodec addrToText addrFromText coinCodec)

-- | @staking@ is @{ "pools": <object>, "stake": <object> }@.
stakingCodec :: JSONCodec ShelleyGenesisStaking
stakingCodec =
  object "ShelleyGenesisStaking" $
    ShelleyGenesisStaking
      <$> requiredFieldWith "pools" poolsCodec "Initial stake pools" .= sgsPools
      <*> requiredFieldWith "stake" stakeCodec "Initial stake delegation" .= sgsStake
 where
  poolsCodec =
    listMapCodec keyHashToText keyHashFromText (codecViaAeson "StakePoolParams")
  stakeCodec =
    listMapCodec keyHashToText keyHashFromText keyHashCodec

-- | The extra-configuration record (streaming injection), decoded for now via
-- the ledger's aeson instances.
extraConfigCodec :: JSONCodec ShelleyExtraConfig
extraConfigCodec = codecViaAeson "ShelleyExtraConfig"

-- | A 'LM.ListMap' encoded as a JSON object, with text-convertible keys.
listMapCodec ::
  Ord k => (k -> Text) -> (Text -> Either String k) -> JSONCodec v -> JSONCodec (LM.ListMap k v)
listMapCodec toKey fromKey valueCodec' =
  dimapCodec
    (LM.fromList . Map.toList)
    (Map.fromList . LM.toList)
    (mapAsObjectCodec toKey fromKey valueCodec')

keyHashToText :: KeyHash r -> Text
keyHashToText = hashToTextAsHex . unKeyHash

keyHashFromText :: Text -> Either String (KeyHash r)
keyHashFromText = maybe (Left "invalid key hash") (Right . KeyHash) . hashFromTextAsHex

addrToText :: Addr -> Text
addrToText = TE.decodeLatin1 . B16.encode . serialiseAddr

addrFromText :: Text -> Either String Addr
addrFromText t =
  case B16.decode (TE.encodeUtf8 t) of
    Left err -> Left ("invalid address (bad hex): " <> err)
    Right bytes -> maybe (Left "invalid address bytes") Right (decodeAddr bytes)
