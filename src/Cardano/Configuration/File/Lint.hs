-- | Linting of the top-level configuration keys: detecting unrecognised keys.
-- This is the only part of the configuration-file handling that depends on the
-- schema (for the set of recognised keys).
--
-- The checks are pure and return structured 'ConfigWarning's; how (or whether) to
-- surface them — print, log via a tracer, treat as fatal — is left to the caller.
module Cardano.Configuration.File.Lint
  ( ConfigWarning (..)
  , renderConfigWarning
  , configWarnings
  , checkUnknownKeys
  , inVersion1Format
  ) where

import Cardano.Configuration.Schema (recognisedKeys)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (intercalate)

-- | A non-fatal observation about a configuration. Returned by the parser so the
-- caller decides how to surface it (the @cardano-config@ executable prints them
-- to @stderr@; another consumer might log them through its own tracer, or treat
-- them as errors).
data ConfigWarning
  = -- | Top-level keys that no parser recognises: typos, or a component property
    -- placed flat under @Configuration@ instead of under its section. They are
    -- ignored (not resolved into a section).
    UnrecognisedKeys [String]
  | -- | The document was not in the Version1 format (no top-level @Configuration@
    -- envelope), so the parser did not accept it as-is: it was migrated to the
    -- Version1 format (see @Cardano.Configuration.File.Migrate.migrate@) before
    -- parsing. Run @cardano-config migrate@ to update the file on disk.
    MigratedToVersion1
  | -- | A consistency check of warning severity did not hold on the resolved
    -- configuration (e.g. the Mithril snapshot policy under the V2LSM backend
    -- without an @LSMExportPath@). The configuration is still accepted; the
    -- string is the check's description. See @Cardano.Configuration.ConfigCheck@.
    ConsistencyWarning String
  deriving (Eq, Show)

-- | A human-readable rendering of a 'ConfigWarning', matching the text the
-- library used to print itself.
renderConfigWarning :: ConfigWarning -> String
renderConfigWarning = \case
  UnrecognisedKeys ks ->
    "unrecognised configuration key(s): " <> intercalate ", " ks <> " (ignored)"
  MigratedToVersion1 ->
    "the configuration was not in the Version1 format (no top-level Configuration envelope); "
      <> "it was migrated to the Version1 format before parsing "
      <> "(run `cardano-config migrate` to update the file)"
  ConsistencyWarning msg -> msg

-- | All warnings for an (unwrapped) configuration object.
--
-- With the parser accepting only the Version1 format (a document that is not is
-- migrated first, which groups every component under its section), the only key
-- warning left is for keys that none of the parsers recognise — typos, or a
-- component property placed flat under @Configuration@ rather than under its
-- section. There is no longer any \"shadowed\" or \"legacy single-file\" handling:
-- a misplaced key is simply unrecognised, not resolved.
configWarnings :: Value -> [ConfigWarning]
configWarnings = checkUnknownKeys

-- | Top-level keys that none of the parsers recognise. Only the section keys, the
-- tracing keys and the envelope annotations are recognised at the @Configuration@
-- level; a component's own property names are recognised only under its section,
-- so one placed flat here is reported (and ignored, not resolved).
checkUnknownKeys :: Value -> [ConfigWarning]
checkUnknownKeys = \case
  Object o ->
    let unknown = [K.toString k | k <- KM.keys o, K.toText k `notElem` recognisedKeys]
     in [UnrecognisedKeys unknown | not (null unknown)]
  _ -> []

-- | Whether the raw document is in the Version1 format: an object carrying the
-- top-level @Configuration@ envelope. This is the parser's accept\/migrate gate —
-- a document in this form is parsed as-is; one that is not is migrated to it
-- first (see 'MigratedToVersion1'). Operates on the /raw/ top-level value, before
-- the envelope is split off.
inVersion1Format :: Value -> Bool
inVersion1Format = \case
  Object o -> KM.member "Configuration" o
  _ -> False
