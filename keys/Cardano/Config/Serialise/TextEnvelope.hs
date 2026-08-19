{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- | TextEnvelope Serialisation
--
-- The envelope type, its JSON codec and the return-type-polymorphic decoders.
-- All of it is pure and era-independent: opening and writing envelope files is
-- left to the caller.
module Cardano.Config.Serialise.TextEnvelope
  ( HasTextEnvelope (..)
  , TextEnvelope (..)
  , TextEnvelopeType (..)
  , TextEnvelopeDescr (..)
  , textEnvelopeRawCBOR
  , TextEnvelopeError (..)
  , renderTextEnvelopeError
  , serialiseToTextEnvelope
  , deserialiseFromTextEnvelope
  , expectTextEnvelopeOfType
  , textEnvelopeToJSON
  , serialiseTextEnvelope
  , legacyComparison

    -- * Reading one of several key types
  , FromSomeType (..)
  , deserialiseFromTextEnvelopeAnyOf
  , decodeTextEnvelopeJSON
  , deserialiseFromTextEnvelopeJSON
  , deserialiseFromTextEnvelopeJSONAnyOf

    -- * Data family instances
  , AsType (..)
  )
where

import Cardano.Config.Key.HasTypeProxy
import Cardano.Config.Serialise.Cbor
import Cardano.Config.Serialise.Orphans ()
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (Config (..), defConfig, encodePretty', keyOrder)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Data (Data)
import Data.List qualified as List
import Data.Maybe (fromMaybe)
import Data.String (IsString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text

-- ----------------------------------------------------------------------------
-- Text envelopes
--

newtype TextEnvelopeType = TextEnvelopeType String
  deriving (Eq, Show, Data)
  deriving newtype (IsString, Semigroup, ToJSON, FromJSON)

newtype TextEnvelopeDescr = TextEnvelopeDescr String
  deriving (Eq, Show, Data)
  deriving newtype (IsString, Semigroup, ToJSON, FromJSON)

-- | A 'TextEnvelope' is a structured envelope for serialised binary values
-- with an external format with a semi-readable textual format.
--
-- It contains a \"type\" field, e.g. \"PublicKeyByron\" or \"TxSignedShelley\"
-- to indicate the type of the encoded data. This is used as a sanity check
-- and to help readers.
--
-- It also contains a \"title\" field which is free-form, and could be used
-- to indicate the role or purpose to a reader.
data TextEnvelope = TextEnvelope
  { teType :: !TextEnvelopeType
  , teDescription :: !TextEnvelopeDescr
  , teRawCBOR :: !ByteString
  }
  deriving (Eq, Show)

instance HasTypeProxy TextEnvelope where
  data AsType TextEnvelope = AsTextEnvelope
  proxyToAsType _ = AsTextEnvelope

instance ToJSON TextEnvelope where
  toJSON TextEnvelope{teType, teDescription, teRawCBOR} =
    object
      [ "type" .= teType
      , "description" .= teDescription
      , "cborHex" .= Text.decodeUtf8 (Base16.encode teRawCBOR)
      ]

instance FromJSON TextEnvelope where
  parseJSON = withObject "TextEnvelope" $ \v ->
    TextEnvelope
      <$> (v .: "type")
      <*> (v .: "description")
      <*> (parseJSONBase16 =<< v .: "cborHex")
   where
    parseJSONBase16 v =
      either fail return . Base16.decode . Text.encodeUtf8 =<< parseJSON v

textEnvelopeJsonConfig :: Config
textEnvelopeJsonConfig = defConfig{confCompare = textEnvelopeJsonKeyOrder}

textEnvelopeJsonKeyOrder :: Text -> Text -> Ordering
textEnvelopeJsonKeyOrder = keyOrder ["type", "description", "cborHex"]

textEnvelopeRawCBOR :: TextEnvelope -> ByteString
textEnvelopeRawCBOR = teRawCBOR

-- | The errors that the pure 'TextEnvelope' parsing\/decoding functions can return.
data TextEnvelopeError
  = -- | expected, actual
    TextEnvelopeTypeError ![TextEnvelopeType] !TextEnvelopeType
  | TextEnvelopeDecodeError !DecoderError
  | TextEnvelopeAesonDecodeError !String
  | TextEnvelopeUnknownKeyWitness !TextEnvelopeDescr
  | TextEnvelopeUnknownType !Text
  deriving (Eq, Show, Data)

-- | Render a 'TextEnvelopeError' as human-readable text.
--
-- Error types here carry a renderer rather than a class instance, following the
-- convention of the rest of this package.
renderTextEnvelopeError :: TextEnvelopeError -> Text
renderTextEnvelopeError = \case
  TextEnvelopeTypeError [TextEnvelopeType expType] (TextEnvelopeType actType) ->
    mconcat
      [ "TextEnvelope type error: "
      , " Expected: " <> Text.pack expType
      , " Actual: " <> Text.pack actType
      ]
  TextEnvelopeTypeError expTypes (TextEnvelopeType actType) ->
    mconcat
      [ "TextEnvelope type error: "
      , " Expected one of: "
      , mconcat $ List.intersperse ", " [Text.pack expType | TextEnvelopeType expType <- expTypes]
      , " Actual: " <> Text.pack actType
      ]
  TextEnvelopeAesonDecodeError decErr ->
    "TextEnvelope aeson decode error: " <> Text.pack decErr
  TextEnvelopeDecodeError decErr ->
    "TextEnvelope decode error: " <> Text.pack (show decErr)
  TextEnvelopeUnknownKeyWitness desc ->
    "Unknown key witness specified: " <> Text.pack (show desc)
  TextEnvelopeUnknownType unknownType ->
    "Unknown TextEnvelope type: " <> unknownType

-- | Check that the \"type\" of the 'TextEnvelope' is as expected.
--
-- For example, one might check that the type is \"TxSignedShelley\".
expectTextEnvelopeOfType :: TextEnvelopeType -> TextEnvelope -> Either TextEnvelopeError ()
expectTextEnvelopeOfType expectedType TextEnvelope{teType = actualType} =
  unless (expectedType `legacyComparison` actualType) $
    Left (TextEnvelopeTypeError [expectedType] actualType)

-- | This is a backwards-compatibility patch to ensure that old envelopes
-- generated by 'serialiseTxLedgerCddl' can be deserialised after switching
-- to the 'serialiseToTextEnvelope'.
legacyComparison :: TextEnvelopeType -> TextEnvelopeType -> Bool
legacyComparison (TextEnvelopeType expectedType) (TextEnvelopeType actualType) =
  case (expectedType, actualType) of
    ("TxSignedShelley", "Witnessed Tx ShelleyEra") -> True
    ("Tx AllegraEra", "Witnessed Tx AllegraEra") -> True
    ("Tx MaryEra", "Witnessed Tx MaryEra") -> True
    ("Tx AlonzoEra", "Witnessed Tx AlonzoEra") -> True
    ("Tx BabbageEra", "Witnessed Tx BabbageEra") -> True
    ("Tx ConwayEra", "Witnessed Tx ConwayEra") -> True
    ("TxSignedShelley", "Unwitnessed Tx ShelleyEra") -> True
    ("Tx AllegraEra", "Unwitnessed Tx AllegraEra") -> True
    ("Tx MaryEra", "Unwitnessed Tx MaryEra") -> True
    ("Tx AlonzoEra", "Unwitnessed Tx AlonzoEra") -> True
    ("Tx BabbageEra", "Unwitnessed Tx BabbageEra") -> True
    ("Tx ConwayEra", "Unwitnessed Tx ConwayEra") -> True
    ("Certificate", "CertificateConway") -> True
    ("Certificate", "CertificateShelley") -> True
    (expectedOther, expectedActual) -> expectedOther == expectedActual

-- ----------------------------------------------------------------------------
-- Serialisation in text envelope format
--

class SerialiseAsCBOR a => HasTextEnvelope a where
  textEnvelopeType :: AsType a -> TextEnvelopeType

  textEnvelopeDefaultDescr :: a -> TextEnvelopeDescr
  textEnvelopeDefaultDescr _ = ""

serialiseToTextEnvelope ::
  forall a.
  HasTextEnvelope a =>
  Maybe TextEnvelopeDescr -> a -> TextEnvelope
serialiseToTextEnvelope mbDescr a =
  TextEnvelope
    { teType = textEnvelopeType ttoken
    , teDescription = fromMaybe (textEnvelopeDefaultDescr a) mbDescr
    , teRawCBOR = serialiseToCBOR a
    }
 where
  ttoken = asType :: AsType a

deserialiseFromTextEnvelope ::
  forall a.
  HasTextEnvelope a =>
  TextEnvelope ->
  Either TextEnvelopeError a
deserialiseFromTextEnvelope te = do
  expectTextEnvelopeOfType (textEnvelopeType ttoken) te
  first TextEnvelopeDecodeError $
    deserialiseFromCBOR ttoken (teRawCBOR te)
 where
  ttoken = asType :: AsType a

deserialiseFromTextEnvelopeAnyOf ::
  [FromSomeType HasTextEnvelope b] ->
  TextEnvelope ->
  Either TextEnvelopeError b
deserialiseFromTextEnvelopeAnyOf types te =
  case List.find matching types of
    Nothing ->
      Left (TextEnvelopeTypeError expectedTypes actualType)
    Just (FromSomeType ttoken f) ->
      first TextEnvelopeDecodeError $
        f <$> deserialiseFromCBOR ttoken (teRawCBOR te)
 where
  actualType = teType te
  expectedTypes =
    [ textEnvelopeType ttoken
    | FromSomeType ttoken _f <- types
    ]

  matching (FromSomeType ttoken _f) = textEnvelopeType ttoken `legacyComparison` actualType

-- | Decode a JSON-encoded 'TextEnvelope' from a strict 'ByteString' (UTF-8).
-- Returns 'TextEnvelopeAesonDecodeError' if the JSON parsing fails.
decodeTextEnvelopeJSON :: ByteString -> Either TextEnvelopeError TextEnvelope
decodeTextEnvelopeJSON bs =
  first TextEnvelopeAesonDecodeError $ Aeson.eitherDecodeStrict' bs

-- | Deserialise a value from a JSON-encoded text envelope 'ByteString' (UTF-8).
-- This performs no file I\/O. Returns 'TextEnvelopeAesonDecodeError' for JSON
-- parse failures, or downstream errors from 'deserialiseFromTextEnvelope' for
-- type mismatches and CBOR decoding failures.
deserialiseFromTextEnvelopeJSON ::
  HasTextEnvelope a =>
  ByteString -> Either TextEnvelopeError a
deserialiseFromTextEnvelopeJSON bs =
  decodeTextEnvelopeJSON bs >>= deserialiseFromTextEnvelope

-- | Like 'deserialiseFromTextEnvelopeJSON' but accepts multiple target types.
-- This performs no file I\/O. Returns 'TextEnvelopeAesonDecodeError' for JSON
-- parse failures, or downstream errors from 'deserialiseFromTextEnvelopeAnyOf'
-- for type mismatches and CBOR decoding failures.
deserialiseFromTextEnvelopeJSONAnyOf ::
  [FromSomeType HasTextEnvelope b] ->
  ByteString ->
  Either TextEnvelopeError b
deserialiseFromTextEnvelopeJSONAnyOf types bs =
  decodeTextEnvelopeJSON bs >>= deserialiseFromTextEnvelopeAnyOf types

textEnvelopeToJSON :: HasTextEnvelope a => Maybe TextEnvelopeDescr -> a -> LBS.ByteString
textEnvelopeToJSON mbDescr a =
  serialiseTextEnvelope $ serialiseToTextEnvelope mbDescr a

-- | Serialise text envelope to pretty JSON
serialiseTextEnvelope :: TextEnvelope -> LBS.ByteString
serialiseTextEnvelope te = encodePretty' textEnvelopeJsonConfig te <> "\n"
