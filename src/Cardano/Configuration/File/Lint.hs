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
  ) where

import Cardano.Configuration.Schema (recognisedKeys)
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
  = -- | Top-level keys that no parser recognises: typos, or a component property
    -- placed flat under @Configuration@ instead of under its section. They are
    -- ignored (not resolved into a section).
    UnrecognisedKeys [String]
  | -- | The document was not in the current canonical format, so migrating it (see
    -- @Cardano.Configuration.File.Migrate.migrate@) changed it before parsing —
    -- either it was not in the Version1 envelope, or it still used a pre-rename
    -- field name, or it carried an obsolete key. Run @cardano-config migrate@ to
    -- update the file on disk.
    MigratedToCurrentFormat
  | -- | While migrating, both the old and the current name of a renamed field
    -- were present at the same level (@(old, new)@). The value under the current
    -- name is kept and the one under the old name is dropped. Reconcile the two by
    -- hand if the dropped value was the one you meant to keep.
    RenamedKeyCollision Text Text
  | -- | While migrating, a key appeared both as a top-level sibling of the
    -- @Configuration@ envelope and inside it. The value inside @Configuration@ (the
    -- canonical location) is kept and the top-level one is dropped.
    EnvelopeKeyCollision Text
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
  MigratedToCurrentFormat ->
    "the configuration was not in the current canonical format; "
      <> "it was migrated before parsing "
      <> "(run `cardano-config migrate` to update the file)"
  RenamedKeyCollision old new ->
    "both the old key \""
      <> T.unpack old
      <> "\" and its current name \""
      <> T.unpack new
      <> "\" are present; keeping \""
      <> T.unpack new
      <> "\" and dropping \""
      <> T.unpack old
      <> "\""
  EnvelopeKeyCollision key ->
    "the key \""
      <> T.unpack key
      <> "\" appears both at the top level and inside Configuration; "
      <> "keeping the value inside Configuration"
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
