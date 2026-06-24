-- | Linting of the top-level configuration keys: detecting unrecognised keys,
-- keys shadowed by a component supplied as its own section, and use of the legacy
-- single-file form. This is the only part of the configuration-file handling that
-- depends on the schema (for the set of recognised keys and the per-component key
-- listing).
--
-- The checks are pure and return structured 'ConfigWarning's; how (or whether) to
-- surface them — print, log via a tracer, treat as fatal — is left to the caller.
module Cardano.Configuration.File.Lint (
  ConfigWarning (..),
  renderConfigWarning,
  configWarnings,
  checkUnknownKeys,
  checkShadowedKeys,
  checkLegacyFormat,
) where

import Cardano.Configuration.Schema (componentPropertyNames, recognisedKeys)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as T

-- | A non-fatal observation about a configuration. Returned by the parser so the
-- caller decides how to surface it (the @cardano-config@ executable prints them
-- to @stderr@; another consumer might log them through its own tracer, or treat
-- them as errors).
data ConfigWarning
  = -- | Top-level keys that no parser recognises (typically typos); they are
    -- ignored.
    UnrecognisedKeys [String]
  | -- | Top-level keys ignored because their component was also given as its own
    -- section (which wins). Each pair is @(section, key)@.
    ShadowedKeys [(Text, Text)]
  | -- | The configuration uses the legacy single-file form (component keys at the
    -- top level) rather than the recommended split-file form.
    LegacySingleFileFormat
  deriving (Eq, Show)

-- | A human-readable rendering of a 'ConfigWarning', matching the text the
-- library used to print itself.
renderConfigWarning :: ConfigWarning -> String
renderConfigWarning = \case
  UnrecognisedKeys ks ->
    "unrecognised configuration key(s): " <> intercalate ", " ks <> " (ignored)"
  ShadowedKeys sks ->
    "top-level configuration key(s) ignored because their component is given as a separate section: "
      <> intercalate ", " (map describe sks)
   where
    describe (section, key) = T.unpack key <> " (shadowed by the " <> T.unpack section <> " section)"
  LegacySingleFileFormat ->
    "the configuration uses the legacy single-file form (component keys at the top level); "
      <> "consider porting it to the split-file form (each component under its section key)"

-- | All warnings for an (unwrapped) configuration object.
configWarnings :: Value -> [ConfigWarning]
configWarnings value =
  checkUnknownKeys value <> checkShadowedKeys value <> checkLegacyFormat value

-- | Top-level keys that none of the parsers recognise.
checkUnknownKeys :: Value -> [ConfigWarning]
checkUnknownKeys = \case
  Object o ->
    let unknown = [K.toString k | k <- KM.keys o, K.toText k `notElem` recognisedKeys]
     in [UnrecognisedKeys unknown | not (null unknown)]
  _ -> []

-- | Top-level keys shadowed by a component supplied as its own section: when a
-- section key (e.g. @TestingConfig@) is present, that component's keys are read
-- from the section, so any sibling top-level key belonging to the same component
-- (e.g. a top-level @DijkstraGenesisFile@) is silently ignored.
--
-- This looks only at the keys the user wrote in this object; the per-component
-- base defaults are merged separately inside
-- 'Cardano.Configuration.File.Merge.parseSection' and never appear here, so they
-- cannot trigger it.
checkShadowedKeys :: Value -> [ConfigWarning]
checkShadowedKeys = \case
  Object o ->
    let present = map K.toText (KM.keys o)
        shadowed =
          [ (section, key)
          | (section, keys) <- componentPropertyNames
          , section `elem` present
          , key <- keys
          , key `elem` present
          ]
     in [ShadowedKeys shadowed | not (null shadowed)]
  _ -> []

-- | Whether the configuration uses the legacy single-file form — i.e. any
-- component's keys appear flat at the top level rather than under its section.
checkLegacyFormat :: Value -> [ConfigWarning]
checkLegacyFormat = \case
  Object o ->
    let present = map K.toText (KM.keys o)
        flat = [key | (_, keys) <- componentPropertyNames, key <- keys, key `elem` present]
     in [LegacySingleFileFormat | not (null flat)]
  _ -> []
