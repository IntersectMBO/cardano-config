-- | The JSON layering engine: reading files, deep-merging configuration sources
-- and running a component's codec. This module knows nothing about which keys
-- the parsers recognise (that is "Cardano.Configuration.File.Lint") nor about the
-- overall orchestration (that is "Cardano.Configuration.File").
module Cardano.Configuration.File.Merge
  ( decodeValueFile
  , runCodec
  , mergeValues
  , loadSectionSource
  , loadBaseDefault
  , sectionUserLayer
  , parseSection
  , splitEnvelope
  ) where

import Cardano.Configuration.File.Error (ConfigurationParsingError (..))
import Control.Exception (throwIO)
import Data.Aeson (FromJSON, Value (..), parseJSON)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (JSONPathElement (..), iparseEither)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml
import Paths_cardano_config (getDataFileName)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | Read and decode a YAML\/JSON file into a 'Value', reporting syntax errors as
-- a 'ConfigurationParsingError' that names the file and section.
decodeValueFile ::
  -- | The section being read, for error reporting.
  Maybe String ->
  -- | The file to read.
  FilePath ->
  IO Value
decodeValueFile section fp = do
  result <- Yaml.decodeFileEither fp
  case result of
    Left e ->
      throwIO $
        ConfigurationParsingError (Just fp) section [] (Yaml.prettyPrintParseException e)
    Right v -> pure v

-- | Run a component parser on a 'Value', turning a failure into a structured
-- 'ConfigurationParsingError' carrying the file, section and JSON path.
runCodec ::
  FromJSON a =>
  -- | The sub-file the value came from, if any.
  Maybe FilePath ->
  -- | The section being parsed, for error reporting.
  String ->
  -- | The value to parse.
  Value ->
  IO a
runCodec mFile section value =
  case iparseEither parseJSON value of
    Left (path, msg) -> throwIO $ ConfigurationParsingError mFile (Just section) path msg
    Right a -> pure a

-- | Deep, right-biased merge of two JSON values: two objects are merged key by
-- key (a key present in both is merged recursively), and for anything else the
-- second (later) value wins. Used to layer configuration sources so that a later
-- file in a list overrides an earlier one.
mergeValues :: Value -> Value -> Value
mergeValues (Object earlier) (Object later) = Object (KM.unionWith mergeValues earlier later)
mergeValues _ later = later

-- | Resolve a single section source — a path to a sub-file (a string) or an
-- inline object — to its 'Value'.
loadSectionSource :: FilePath -> String -> Value -> IO Value
loadSectionSource root section src =
  case src of
    String path -> do
      let fp = root </> T.unpack path
      exists <- doesFileExist fp
      if exists
        then decodeValueFile (Just section) fp
        else
          throwIO $
            ConfigurationParsingError
              (Just fp)
              (Just section)
              [Key (K.fromString section)]
              "the referenced configuration file does not exist"
    Object _ -> pure src
    _ ->
      throwIO $
        ConfigurationParsingError
          Nothing
          (Just section)
          [Key (K.fromString section)]
          "expected a path to a configuration file (a string) or an inline object"

-- | The always-applied base default for a section, read from the package data
-- files (@defaults\/\<Section\>.json@), if one ships for it.
loadBaseDefault :: String -> IO (Maybe Value)
loadBaseDefault section = do
  fp <- getDataFileName ("defaults/" <> section <> ".json")
  exists <- doesFileExist fp
  if exists
    then Just <$> decodeValueFile (Just section) fp
    else pure Nothing

-- | The configuration layer the user supplied for a section: the top-level
-- object when the section key is absent (its keys live there), an inline
-- object, a referenced sub-file, or a list of paths\/objects deep-merged in
-- order (a later entry overrides an earlier one, e.g.
-- @[\"Network.variants\/Network.relay.json\"]@).
sectionUserLayer :: FilePath -> Value -> String -> IO Value
sectionUserLayer root configValue section =
  case configValue of
    Object o ->
      case KM.lookup (K.fromString section) o of
        Nothing -> pure configValue
        Just (Array elems) ->
          case toList elems of
            [] ->
              throwIO $
                ConfigurationParsingError
                  Nothing
                  (Just section)
                  [Key (K.fromString section)]
                  "expected a non-empty list of configuration files or objects"
            sources -> foldl1 mergeValues <$> mapM (loadSectionSource root section) sources
        Just source -> loadSectionSource root section source
    _ ->
      throwIO $
        ConfigurationParsingError Nothing Nothing [] "expected the configuration to be a JSON/YAML object"

-- | Parse a single component. The package's base default for the section is
-- always read as the bottom layer; the user's layer (see 'sectionUserLayer') is
-- deep-merged on top. A path to a missing file is an explicit error.
parseSection ::
  FromJSON a =>
  -- | The directory the main file lives in, against which sub-file paths are
  -- resolved.
  FilePath ->
  -- | The (unwrapped) configuration object.
  Value ->
  -- | The section name.
  String ->
  IO a
parseSection root configValue section = do
  base <- loadBaseDefault section
  user <- sectionUserLayer root configValue section
  let withBase = maybe user (`mergeValues` user) base
  runCodec Nothing section withBase

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
      version <- lookupVersion o
      minNodeVersion <- lookupMinNodeVersion o
      pure (version, minNodeVersion, fromMaybe value (KM.lookup "Configuration" o))
    _ ->
      throwIO $
        ConfigurationParsingError Nothing Nothing [] "expected the configuration to be a JSON/YAML object"
 where
  -- A missing @Version@ is the legacy version 1. A present one must be an
  -- integer in range (not e.g. 1.4 or a huge scientific literal): the schema
  -- declares it as an integer, so anything else is a hard error.
  lookupVersion o = case KM.lookup "Version" o of
    Nothing -> pure 1
    Just (Number n) ->
      maybe (throwIO (badVersion ("expected an integer, got " <> show n))) pure (toBoundedInteger n)
    Just _ -> throwIO (badVersion "expected an integer")
  badVersion msg = ConfigurationParsingError Nothing Nothing [Key "Version"] ("invalid Version: " <> msg)
  -- @MinNodeVersion@ is optional and, when present, must be a string.
  lookupMinNodeVersion o = case KM.lookup "MinNodeVersion" o of
    Nothing -> pure Nothing
    Just (String t) -> pure (Just t)
    Just _ ->
      throwIO $
        ConfigurationParsingError
          Nothing
          Nothing
          [Key "MinNodeVersion"]
          "invalid MinNodeVersion: expected a string"
