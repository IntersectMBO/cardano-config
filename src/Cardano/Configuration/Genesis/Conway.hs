{-# OPTIONS_GHC -Wno-orphans #-}

-- | A by-hand @autodocodec@ codec for the Conway-era genesis, decoding the
-- genesis JSON into the ledger's 'ConwayGenesis'. The protocol-parameter fields
-- of @UpgradeConwayPParams@ appear as top-level keys (the ledger unpacks them
-- into the genesis object), alongside @constitution@, @committee@ and the
-- optional @delegs@\/@initialDReps@\/@extraConfig@.
--
-- The scalar, coin, epoch-interval and ratio fields and the PlutusV3 cost model
-- (a flat integer array) are decoded by hand; the deeply-nested governance
-- structures (voting thresholds, constitution, committee, delegation maps and
-- extra config) are decoded via the ledger's aeson instances for now.
module Cardano.Configuration.Genesis.Conway (
  conwayGenesisCodec,
) where

import Autodocodec
import Cardano.Configuration.Genesis.Ledger (
  boundedRationalCodec,
  coinCodec,
  epochIntervalCodec,
 )
import Cardano.Ledger.BaseTypes (UnitInterval, maybeToStrictMaybe, strictMaybeToMaybe)
import Cardano.Ledger.Conway.Genesis (ConwayExtraConfig, ConwayGenesis (..))
import Cardano.Ledger.Conway.PParams (
  DRepVotingThresholds (..),
  PoolVotingThresholds (..),
  UpgradeConwayPParams (..),
 )
import Cardano.Ledger.Plutus.CostModels (CostModel, getCostModelParams, mkCostModel)
import Cardano.Ledger.Plutus.Language (Language (PlutusV3))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word16)

instance HasCodec ConwayGenesis where
  codec = conwayGenesisCodec

-- | The codec for the Conway genesis.
conwayGenesisCodec :: JSONCodec ConwayGenesis
conwayGenesisCodec =
  object "ConwayGenesis" $
    mk
      <$> requiredFieldWith "poolVotingThresholds" poolVotingThresholdsCodec "Pool voting thresholds"
        .= upgrade ucppPoolVotingThresholds
      <*> requiredFieldWith "dRepVotingThresholds" dRepVotingThresholdsCodec "DRep voting thresholds"
        .= upgrade ucppDRepVotingThresholds
      <*> requiredFieldWith "committeeMinSize" (codec @Word16) "Minimum committee size"
        .= upgrade ucppCommitteeMinSize
      <*> requiredFieldWith "committeeMaxTermLength" epochIntervalCodec "Maximum committee term length"
        .= upgrade ucppCommitteeMaxTermLength
      <*> requiredFieldWith "govActionLifetime" epochIntervalCodec "Governance action lifetime"
        .= upgrade ucppGovActionLifetime
      <*> requiredFieldWith "govActionDeposit" coinCodec "Governance action deposit"
        .= upgrade ucppGovActionDeposit
      <*> requiredFieldWith "dRepDeposit" coinCodec "DRep registration deposit"
        .= upgrade ucppDRepDeposit
      <*> requiredFieldWith "dRepActivity" epochIntervalCodec "DRep activity period"
        .= upgrade ucppDRepActivity
      <*> requiredFieldWith "minFeeRefScriptCostPerByte" (boundedRationalCodec "minFeeRefScriptCostPerByte") "Reference-script cost per byte"
        .= upgrade ucppMinFeeRefScriptCostPerByte
      <*> requiredFieldWith "plutusV3CostModel" plutusV3CostModelCodec "Plutus V3 cost model"
        .= upgrade ucppPlutusV3CostModel
      <*> requiredFieldWith "constitution" (codecViaAeson "Constitution") "The initial constitution"
        .= cgConstitution
      <*> requiredFieldWith "committee" (codecViaAeson "Committee") "The initial constitutional committee"
        .= cgCommittee
      <*> optionalFieldWithOmittedDefaultWith "delegs" (codecViaAeson "Delegs") mempty "Initial stake delegations"
        .= cgDelegs
      <*> optionalFieldWithOmittedDefaultWith "initialDReps" (codecViaAeson "InitialDReps") mempty "Initial DReps"
        .= cgInitialDReps
      <*> extraConfigField
        .= cgExtraConfig
  where
    upgrade f = f . cgUpgradePParams
    extraConfigField =
      dimapCodec maybeToStrictMaybe strictMaybeToMaybe $
        optionalFieldWith "extraConfig" extraConfigCodec "Extra streaming-injection configuration"
    mk pvt drvt cms cmtl gal gad drd dra mfr pv3 constitution committee delegs initialDReps extraConfig =
      ConwayGenesis
        ( UpgradeConwayPParams pvt drvt cms cmtl gal gad drd dra mfr pv3
        )
        constitution
        committee
        delegs
        initialDReps
        extraConfig

-- | Pool voting thresholds: an object of five 'UnitInterval's.
poolVotingThresholdsCodec :: JSONCodec PoolVotingThresholds
poolVotingThresholdsCodec =
  object "PoolVotingThresholds" $
    PoolVotingThresholds
      <$> unitField "motionNoConfidence" .= pvtMotionNoConfidence
      <*> unitField "committeeNormal" .= pvtCommitteeNormal
      <*> unitField "committeeNoConfidence" .= pvtCommitteeNoConfidence
      <*> unitField "hardForkInitiation" .= pvtHardForkInitiation
      <*> unitField "ppSecurityGroup" .= pvtPPSecurityGroup

-- | DRep voting thresholds: an object of ten 'UnitInterval's.
dRepVotingThresholdsCodec :: JSONCodec DRepVotingThresholds
dRepVotingThresholdsCodec =
  object "DRepVotingThresholds" $
    DRepVotingThresholds
      <$> unitField "motionNoConfidence" .= dvtMotionNoConfidence
      <*> unitField "committeeNormal" .= dvtCommitteeNormal
      <*> unitField "committeeNoConfidence" .= dvtCommitteeNoConfidence
      <*> unitField "updateToConstitution" .= dvtUpdateToConstitution
      <*> unitField "hardForkInitiation" .= dvtHardForkInitiation
      <*> unitField "ppNetworkGroup" .= dvtPPNetworkGroup
      <*> unitField "ppEconomicGroup" .= dvtPPEconomicGroup
      <*> unitField "ppTechnicalGroup" .= dvtPPTechnicalGroup
      <*> unitField "ppGovGroup" .= dvtPPGovGroup
      <*> unitField "treasuryWithdrawal" .= dvtTreasuryWithdrawal

-- | A required field holding a 'UnitInterval' (a bounded ratio).
unitField :: Text -> ObjectCodec UnitInterval UnitInterval
unitField key = requiredFieldWith key (boundedRationalCodec key) ("Threshold: " <> key)

-- | The PlutusV3 cost model is a flat JSON array of integers.
plutusV3CostModelCodec :: JSONCodec CostModel
plutusV3CostModelCodec = bimapCodec decodeCM encodeCM (codec @[Int64])
  where
    encodeCM = getCostModelParams
    decodeCM params =
      case mkCostModel PlutusV3 params of
        Left err -> Left ("invalid PlutusV3 cost model: " <> show err)
        Right m -> Right m

-- | The extra-configuration record, decoded for now via the ledger's aeson
-- instance.
extraConfigCodec :: JSONCodec ConwayExtraConfig
extraConfigCodec = codecViaAeson "ConwayExtraConfig"
