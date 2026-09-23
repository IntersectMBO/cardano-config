-- | The JSON layering engine: splitting the envelope, deep-merging a section's
-- base default with the user's object and running a component's codec. The
-- configuration is one file, so the only files read here are the configuration
-- itself and the @defaults\/@ compiled into the binary. This module knows
-- nothing about which keys the parsers recognise (that is
-- "Cardano.Configuration.File.Lint") nor about the overall orchestration (that
-- is "Cardano.Configuration.File").
module Cardano.Configuration.File.Merge
  ( decodeValueFile
  , decodeValueBytes
  , runCodec
  , mergeValues
  , loadBaseDefault
  , sectionUserLayer
  , parseSection
  , splitEnvelope
  , declaredFormatVersion
  ) where

import Cardano.Configuration.Embedded (embeddedDefaults)
import Cardano.Configuration.File.Error (ConfigurationParsingError (..))
import Cardano.Ledger.BaseTypes (StrictMaybe (..), maybeToStrictMaybe)
import Control.Exception (throwIO)
import Data.Aeson (FromJSON, Value (..), parseJSON)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (JSONPathElement (..), iparseEither)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml

-- | Read and decode a YAML\/JSON file into a 'Value', reporting syntax errors as
-- a 'ConfigurationParsingError' that names the file. Only the configuration
-- file itself is read this way, so there is no section to name.
decodeValueFile :: FilePath -> IO Value
decodeValueFile fp = BS.readFile fp >>= decodeValueBytes Nothing fp

-- | Decode already-read YAML\/JSON bytes into a 'Value', reporting syntax errors
-- against the given name. Used for the files embedded into the binary (see
-- "Cardano.Configuration.Embedded"), which have no path on disk to read.
decodeValueBytes ::
  -- | The section being read, for error reporting.
  Maybe String ->
  -- | The name the bytes came from, for error reporting.
  FilePath ->
  -- | The bytes to decode.
  ByteString ->
  IO Value
decodeValueBytes section fp bytes =
  case Yaml.decodeEither' bytes of
    Left e ->
      throwIO $
        ConfigurationParsingError
          (SJust fp)
          (maybeToStrictMaybe section)
          []
          (Yaml.prettyPrintParseException e)
    Right v -> pure v

-- | Run a component parser on a 'Value', turning a failure into a structured
-- 'ConfigurationParsingError' carrying the section and JSON path. Every value
-- parsed here comes from the configuration file, so the error names no other
-- file.
runCodec ::
  FromJSON a =>
  -- | The section being parsed, for error reporting.
  String ->
  -- | The value to parse.
  Value ->
  IO a
runCodec section value =
  case iparseEither parseJSON value of
    Left (path, msg) -> throwIO $ ConfigurationParsingError SNothing (SJust section) path msg
    Right a -> pure a

-- | Deep, right-biased merge of two JSON values: two objects are merged key by
-- key (a key present in both is merged recursively), and for anything else the
-- second (later) value wins. Used to layer a section's user-supplied value on
-- top of its always-applied base default, so the user's value wins.
mergeValues :: Value -> Value -> Value
mergeValues (Object earlier) (Object later) = Object (KM.unionWith mergeValues earlier later)
mergeValues _ later = later

-- | The always-applied base default for a section, read from the
-- @defaults\/\<Section\>.json@ embedded into the binary (see
-- "Cardano.Configuration.Embedded"), if one ships for it.
loadBaseDefault :: String -> IO (Maybe Value)
loadBaseDefault section =
  case Map.lookup name embeddedDefaults of
    Nothing -> pure Nothing
    Just bytes -> Just <$> decodeValueBytes (Just section) ("defaults/" <> name) bytes
 where
  name = section <> ".json"

-- | The configuration layer the user supplied for a section: the inline object
-- given under the section key. A component is read only from its own section
-- key; a section that is absent contributes no user layer (so the component
-- takes its base defaults). Component keys placed flat under @Configuration@ are
-- /not/ resolved into their section — they are left unrecognised (see
-- 'Cardano.Configuration.File.Lint.checkUnknownKeys'). Non-enveloped documents,
-- where the keys are flat, are migrated (grouped into sections) before reaching
-- here.
--
-- The whole configuration lives in one file. A section whose value is anything
-- other than an object — a path to a separate file, as older configurations
-- wrote it — is rejected here.
sectionUserLayer :: Value -> String -> IO Value
sectionUserLayer configValue section =
  case configValue of
    Object o ->
      case KM.lookup (K.fromString section) o of
        Nothing -> pure (Object KM.empty)
        Just (Object user) -> pure (Object user)
        Just _ ->
          throwIO $
            ConfigurationParsingError
              SNothing
              (SJust section)
              [Key (K.fromString section)]
              ( "expected an inline configuration object. A path to a separate file is no "
                  <> "longer accepted: copy that file's contents in here."
              )
    _ ->
      throwIO $
        ConfigurationParsingError SNothing SNothing [] "expected the configuration to be a JSON/YAML object"

-- | Parse a single component. The package's base default for the section is
-- always read as the bottom layer; the user's layer (see 'sectionUserLayer') is
-- deep-merged on top.
parseSection ::
  FromJSON a =>
  -- | The (unwrapped) configuration object.
  Value ->
  -- | The section name.
  String ->
  IO a
parseSection configValue section = do
  base <- loadBaseDefault section
  user <- sectionUserLayer configValue section
  let withBase = maybe user (`mergeValues` user) base
  runCodec section withBase

-- | Split the optional configuration envelope @{ \"Version\": N,
-- \"MinNodeVersion\": \"x.y.z\", \"Configuration\": {..} }@ into the version, the
-- optional minimum node version and the configuration object. A document that is
-- not wrapped in an envelope is treated as the legacy version-1 format, in which
-- the configuration keys sit at the top level (and the optional flat @Version@
-- and @MinNodeVersion@ keys may still appear there).
--
-- @MinNodeVersion@ is a top-level annotation (sibling of @Version@), not a
-- configuration component: it records the lowest @cardano-node@ version expected
-- to run this configuration, for a consumer to check.
splitEnvelope :: Value -> IO (Int, Maybe T.Text, Value)
splitEnvelope value =
  case value of
    Object o -> do
      version <- declaredFormatVersion value
      minNodeVersion <- lookupMinNodeVersion o
      pure (version, minNodeVersion, fromMaybe value (KM.lookup "Configuration" o))
    _ ->
      throwIO $
        ConfigurationParsingError SNothing SNothing [] "expected the configuration to be a JSON/YAML object"
 where
  -- @MinNodeVersion@ is optional and, when present, must be a string.
  lookupMinNodeVersion o = case KM.lookup "MinNodeVersion" o of
    Nothing -> pure Nothing
    Just (String t) -> pure (Just t)
    Just _ ->
      throwIO $
        ConfigurationParsingError
          SNothing
          SNothing
          [Key "MinNodeVersion"]
          "invalid MinNodeVersion: expected a string"

-- | The format version a document declares, read before any migration, so the
-- caller can reject a version this library does not write and warn about one it
-- migrates.
--
-- A missing @Version@ is the legacy version 1: a fixed historical fact about
-- unversioned documents, not 'Cardano.Configuration.Schema.currentFormatVersion'.
-- A present one must be an integer in range, since the schema declares it as an
-- integer. A value that is not an object reports 1 and fails later, where the
-- error names the real problem.
declaredFormatVersion :: Value -> IO Int
declaredFormatVersion (Object o) = case KM.lookup "Version" o of
  Nothing -> pure 1
  Just (Number n) ->
    maybe (throwIO (badVersion ("expected an integer, got " <> show n))) pure (toBoundedInteger n)
  Just _ -> throwIO (badVersion "expected an integer")
 where
  badVersion msg = ConfigurationParsingError SNothing SNothing [Key "Version"] ("invalid Version: " <> msg)
declaredFormatVersion _ = pure 1
