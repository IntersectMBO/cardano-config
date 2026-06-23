{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Reusable @autodocodec@ codecs for the cardano-ledger leaf types that appear
-- in the era genesis files (intervals, coins, hashes, addresses, …). These are
-- written by hand so the genesis codecs do not depend on the ledger's own aeson
-- instances; the on-the-wire encoding matches those instances exactly.
module Cardano.Configuration.Genesis.Ledger (
  -- * Numbers and ratios
  boundedRationalCodec,
  nonZeroCodec,
  coinCodec,
  compactCoinCodec,
  coinPerByteCodec,
  epochSizeCodec,
  epochIntervalCodec,
  nominalDiffTimeMicroCodec,

  -- * Enumerations and tagged unions
  networkCodec,
  nonceCodec,
  protVerCodec,

  -- * Hashes, keys and addresses
  keyHashCodec,
  vrfVerKeyHashCodec,
  addrCodec,

  -- * Containers
  mapAsObjectCodec,
) where

import Autodocodec
import Cardano.Crypto.Hash (hashFromTextAsHex, hashToTextAsHex)
import Cardano.Ledger.Address (Addr, decodeAddr, serialiseAddr)
import Cardano.Ledger.BaseTypes (
  BoundedRational (..),
  EpochInterval (..),
  HasZero,
  Network,
  NonZero,
  Nonce (..),
  ProtVer (..),
  nonZero,
  unNonZero,
 )
import Cardano.Ledger.Binary.Version (getVersion32, mkVersion32)
import Cardano.Ledger.Coin (Coin (..), CoinPerByte (..), CompactForm (..))
import Cardano.Ledger.Hashes (KeyHash (..), VRFVerKeyHash (..))
import Data.Aeson (Value (..), withObject, (.:))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Base16 as B16
import Data.Fixed (Micro)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ratio ((%))
import Data.Scientific (base10Exponent, coefficient, fromRationalRepetendLimited, normalize)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word32, Word64)
import Cardano.Slotting.Slot (EpochSize (..))

-- | The number of decimal places that fit in a 'Word64'-backed ratio; matches
-- the ledger's @maxDecimalsWord64@.
maxDecimalsWord64 :: Int
maxDecimalsWord64 = 19

-- | A codec for a bounded rational (@UnitInterval@, @NonNegativeInterval@,
-- @PositiveUnitInterval@, …). Matches the ledger's @BoundedRatio@ JSON: a plain
-- number when the value has a terminating decimal within 'maxDecimalsWord64'
-- digits, otherwise a @{ "numerator", "denominator" }@ object; bounds-checked on
-- decode via 'boundRational'.
boundedRationalCodec :: BoundedRational r => Text -> JSONCodec r
boundedRationalCodec name = bimapCodec decodeBR encodeBR valueCodec <?> name
  where
    encodeBR br = case fromRationalRepetendLimited maxDecimalsWord64 r of
      Right (s, Nothing) -> Aeson.toJSON s
      _ -> Aeson.toJSON r
      where
        r = unboundRational br
    decodeBR v = case v of
      Object _ -> fromRationalBR =<< parseEither Aeson.parseJSON v
      _ -> fromScientificBR =<< parseEither Aeson.parseJSON v
    fromRationalBR r =
      maybe (Left (T.unpack name <> ": value out of bounds")) Right (boundRational r)
    fromScientificBR (normalize -> sci)
      | coeff < 0 = Left (T.unpack name <> ": negative value")
      | exp10 <= 0 =
          if exp10 < negate maxDecimalsWord64
            then Left (T.unpack name <> ": too precise")
            else fromRationalBR (coeff % (10 ^ negate exp10))
      | maxDecimalsWord64 < exp10 = Left (T.unpack name <> ": value too large")
      | otherwise = fromRationalBR (coeff * 10 ^ exp10 % 1)
      where
        coeff = coefficient sci
        exp10 = base10Exponent sci

-- | A codec for @'NonZero' a@: (de)serialise the underlying value, rejecting a
-- zero on the way in, exactly as the ledger's @FromJSON (NonZero a)@ does.
nonZeroCodec :: HasZero a => JSONCodec a -> JSONCodec (NonZero a)
nonZeroCodec inner =
  bimapCodec
    (maybe (Left "expected a non-zero value") Right . nonZero)
    unNonZero
    inner

-- | 'Coin' is a JSON integer (lovelace).
coinCodec :: JSONCodec Coin
coinCodec = dimapCodec Coin unCoin (codec @Integer)

-- | The compact coin form is a JSON 'Word64'.
compactCoinCodec :: JSONCodec (CompactForm Coin)
compactCoinCodec = dimapCodec CompactCoin unCompactCoin (codec @Word64)

-- | 'CoinPerByte' wraps a compact coin and encodes the same way.
coinPerByteCodec :: JSONCodec CoinPerByte
coinPerByteCodec = dimapCodec CoinPerByte unCoinPerByte compactCoinCodec

-- | 'EpochSize' is a JSON 'Word64'.
epochSizeCodec :: JSONCodec EpochSize
epochSizeCodec = dimapCodec EpochSize unEpochSize (codec @Word64)

-- | 'EpochInterval' is a JSON 'Word32'.
epochIntervalCodec :: JSONCodec EpochInterval
epochIntervalCodec = dimapCodec EpochInterval unEpochInterval (codec @Word32)

-- | 'NominalDiffTimeMicro' is a JSON number (seconds, micro precision). We map
-- it through 'Micro' so the encoding matches the ledger's derived instance.
nominalDiffTimeMicroCodec :: (Micro -> a) -> (a -> Micro) -> JSONCodec a
nominalDiffTimeMicroCodec wrap unwrap =
  dimapCodec (wrap . realToFrac) (realToFrac . unwrap) scientificCodec

-- | 'Network' is the JSON string @"Mainnet"@ or @"Testnet"@.
networkCodec :: JSONCodec Network
networkCodec = shownBoundedEnumCodec

-- | The genesis (\"legacy\") encoding of 'Nonce': a tagged object,
-- @{ "tag": "NeutralNonce" }@ or @{ "tag": "Nonce", "contents": "<hex>" }@.
nonceCodec :: JSONCodec Nonce
nonceCodec = bimapCodec decodeNonce encodeNonce valueCodec
  where
    encodeNonce NeutralNonce = Aeson.object ["tag" Aeson..= ("NeutralNonce" :: Text)]
    encodeNonce (Nonce h) =
      Aeson.object ["tag" Aeson..= ("Nonce" :: Text), "contents" Aeson..= hashToTextAsHex h]
    decodeNonce =
      parseEither
        ( withObject "Nonce" $ \o -> do
              tag <- o .: "tag"
              case tag :: Text of
                "NeutralNonce" -> pure NeutralNonce
                "Nonce" -> do
                  contents <- o .: "contents"
                  maybe (fail "invalid nonce hash") (pure . Nonce) (hashFromTextAsHex contents)
                other -> fail ("unknown nonce tag: " <> T.unpack other)
          )

-- | 'ProtVer' is an object @{ "major": <number>, "minor": <number> }@.
protVerCodec :: JSONCodec ProtVer
protVerCodec =
  object "ProtVer" $
    ProtVer
      <$> requiredFieldWith "major" majorCodec "Major protocol version" .= pvMajor
      <*> requiredFieldWith "minor" naturalCodec "Minor protocol version" .= pvMinor
  where
    majorCodec =
      bimapCodec
        (\w -> maybe (Left "invalid major protocol version") Right (mkVersion32 w))
        getVersion32
        (codec @Word32)

-- | A key hash (Blake2b) as a hex string.
keyHashCodec :: JSONCodec (KeyHash r)
keyHashCodec =
  bimapCodec
    (maybe (Left "invalid key hash") (Right . KeyHash) . hashFromTextAsHex)
    (hashToTextAsHex . unKeyHash)
    (codec @Text)

-- | A VRF verification-key hash as a hex string.
vrfVerKeyHashCodec :: JSONCodec (VRFVerKeyHash r)
vrfVerKeyHashCodec =
  bimapCodec
    (maybe (Left "invalid VRF key hash") (Right . VRFVerKeyHash) . hashFromTextAsHex)
    (hashToTextAsHex . unVRFVerKeyHash)
    (codec @Text)

-- | An 'Addr' as the hex encoding of its serialised bytes.
addrCodec :: JSONCodec Addr
addrCodec =
  bimapCodec
    decodeA
    (TE.decodeLatin1 . B16.encode . serialiseAddr)
    (codec @Text)
  where
    decodeA t =
      case B16.decode (TE.encodeUtf8 t) of
        Left err -> Left ("invalid address (bad hex): " <> err)
        Right bytes -> maybe (Left "invalid address bytes") Right (decodeAddr bytes)

-- | Encode a @'Map' k v@ as a JSON object, converting keys to and from text.
mapAsObjectCodec ::
  Ord k => (k -> Text) -> (Text -> Either String k) -> JSONCodec v -> JSONCodec (Map k v)
mapAsObjectCodec toKey fromKey valueCodec' =
  bimapCodec decodeMap (Map.mapKeys toKey) (mapCodec valueCodec')
  where
    decodeMap m =
      fmap Map.fromList $
        traverse (\(t, v) -> (,v) <$> fromKey t) (Map.toList m)
