{-# OPTIONS_GHC -Wno-orphans #-}

-- | A by-hand @autodocodec@ codec for the Alonzo-era genesis, decoding the
-- genesis JSON into the ledger's 'AlonzoGenesis'. The on-the-wire keys and value
-- encodings match the ledger's @FromJSON@/@ToJSON@ instances exactly.
--
-- 'Prices' and 'ExUnits' are encoded with their canonical keys
-- (@priceSteps@\/@priceMemory@, @memory@\/@steps@) but also accept the legacy
-- aliases (@prSteps@\/@prMem@, @exUnitsMem@\/@exUnitsSteps@) on input, matching
-- the ledger. The PlutusV1 cost model (a large, Plutus-internal by-name table)
-- is decoded via the ledger's @CostModels@ instance.
module Cardano.Configuration.Genesis.Alonzo
  ( alonzoGenesisCodec
  ) where

import Autodocodec
import Cardano.Configuration.Genesis.Ledger (boundedRationalCodec, coinCodec)
import Cardano.Ledger.Alonzo.Genesis (AlonzoExtraConfig, AlonzoGenesis (..))
import Cardano.Ledger.Alonzo.PParams (CoinPerWord (..))
import Cardano.Ledger.Plutus.CostModels (CostModel, costModelsValid, mkCostModels)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..), Prices (..))
import Cardano.Ledger.Plutus.Language (Language (PlutusV1))
import Control.Applicative ((<|>))
import Data.Aeson (withObject)
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.Map.Strict as Map
import Data.Word (Word16, Word32)

instance HasCodec AlonzoGenesis where
  codec = alonzoGenesisCodec

-- | The codec for the Alonzo genesis.
alonzoGenesisCodec :: JSONCodec AlonzoGenesis
alonzoGenesisCodec =
  object "AlonzoGenesis" $
    AlonzoGenesis
      <$> requiredFieldWith "lovelacePerUTxOWord" coinPerWordCodec "Lovelace per UTxO word"
        .= agCoinsPerUTxOWord
      <*> requiredFieldWith "costModels" plutusV1CostModelCodec "Plutus V1 cost model"
        .= agPlutusV1CostModel
      <*> requiredFieldWith "executionPrices" pricesCodec "Execution unit prices"
        .= agPrices
      <*> requiredFieldWith "maxTxExUnits" exUnitsCodec "Maximum execution units per transaction"
        .= agMaxTxExUnits
      <*> requiredFieldWith "maxBlockExUnits" exUnitsCodec "Maximum execution units per block"
        .= agMaxBlockExUnits
      <*> requiredFieldWith "maxValueSize" (codec @Word32) "Maximum value size"
        .= agMaxValSize
      <*> requiredFieldWith "collateralPercentage" (codec @Word16) "Collateral percentage"
        .= agCollateralPercentage
      <*> requiredFieldWith "maxCollateralInputs" (codec @Word16) "Maximum number of collateral inputs"
        .= agMaxCollateralInputs
      <*> optionalFieldWith "extraConfig" extraConfigCodec "Extra cost-model configuration"
        .= agExtraConfig

-- | @lovelacePerUTxOWord@ is a 'CoinPerWord' (a JSON integer).
coinPerWordCodec :: JSONCodec CoinPerWord
coinPerWordCodec = dimapCodec CoinPerWord unCoinPerWord coinCodec

-- | The @costModels@ key carries the full @CostModels@ object; in the Alonzo
-- genesis it must contain exactly the PlutusV1 cost model, which we project out.
plutusV1CostModelCodec :: JSONCodec CostModel
plutusV1CostModelCodec = bimapCodec decodeCM encodeCM (codecViaAeson "CostModels")
 where
  encodeCM model = mkCostModels (Map.singleton PlutusV1 model)
  decodeCM cms =
    case Map.toList (costModelsValid cms) of
      [(PlutusV1, m)] -> Right m
      [] -> Left "expected a PlutusV1 cost model"
      _ -> Left "only the PlutusV1 cost model is allowed in the Alonzo genesis"

-- | 'Prices' — encodes @priceSteps@\/@priceMemory@, also accepts the legacy
-- @prSteps@\/@prMem@ on input.
pricesCodec :: JSONCodec Prices
pricesCodec = bimapCodec decodePrices encodePrices valueCodec
 where
  nni = boundedRationalCodec "price"
  encodePrices (Prices prMem' prSteps') =
    Aeson.object
      [ "priceSteps" Aeson..= toJSONVia nni prSteps'
      , "priceMemory" Aeson..= toJSONVia nni prMem'
      ]
  decodePrices = parseEither $
    withObject "Prices" $ \o -> do
      stepsV <- (o Aeson..: "priceSteps") <|> (o Aeson..: "prSteps")
      memV <- (o Aeson..: "priceMemory") <|> (o Aeson..: "prMem")
      prSteps' <- either fail pure (parseEither (parseJSONVia nni) stepsV)
      prMem' <- either fail pure (parseEither (parseJSONVia nni) memV)
      pure (Prices prMem' prSteps')

-- | 'ExUnits' — encodes @memory@\/@steps@, also accepts the legacy
-- @exUnitsMem@\/@exUnitsSteps@ on input.
exUnitsCodec :: JSONCodec ExUnits
exUnitsCodec = bimapCodec decodeEx encodeEx valueCodec
 where
  encodeEx eu =
    Aeson.object
      [ "memory" Aeson..= exUnitsMem eu
      , "steps" Aeson..= exUnitsSteps eu
      ]
  decodeEx = parseEither $
    withObject "ExUnits" $ \o -> do
      mem <- (o Aeson..: "memory") <|> (o Aeson..: "exUnitsMem")
      steps <- (o Aeson..: "steps") <|> (o Aeson..: "exUnitsSteps")
      pure (ExUnits mem steps)

-- | The extra cost-model configuration, decoded for now via the ledger's aeson
-- instance (it carries a full @CostModels@).
extraConfigCodec :: JSONCodec AlonzoExtraConfig
extraConfigCodec = codecViaAeson "AlonzoExtraConfig"
