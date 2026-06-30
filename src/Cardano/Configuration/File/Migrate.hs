-- | Reshape an existing configuration into the recommended Version1 envelope:
-- @{ $schema, Version, MinNodeVersion, Configuration }@, with every component
-- grouped under its section key inside @Configuration@.
--
-- This is a purely structural migration: it preserves the values as written and
-- does /not/ fill in defaults, inline referenced sub-files, or read genesis
-- files. It is meant to port a legacy single-file (flat) or otherwise
-- non-enveloped configuration to the new layout; resolution and validation are
-- left to a subsequent @resolve@.
--
-- The reshaping (see 'migrate'):
--
--   * @$schema@ (the published schema URL) and @Version@ (1) are added when
--     absent; an existing @Version@\/@MinNodeVersion@ is carried through.
--   * a flat top-level property key is nested under the component section that
--     owns it (e.g. @ConsensusMode@ under @ConsensusConfig@, @LedgerDB@ under
--     @StorageConfig@);
--   * a section key (whether an inline object or a path to a sub-file), the
--     @HermodTracing@ key, and any unrecognised key are kept at the
--     @Configuration@ level as-is (so nothing is silently dropped);
--   * a document already in the envelope is reshaped idempotently.
module Cardano.Configuration.File.Migrate
  ( migrate
  ) where

import Cardano.Configuration.File.Merge (mergeValues)
import Cardano.Configuration.Schema (componentPropertyNames, schemaId)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)

-- | Migrate a raw configuration value to the Version1 envelope. A value that is
-- not a JSON\/YAML object is returned unchanged.
migrate :: Value -> Value
migrate (Object top) =
  Object $
    KM.insert "$schema" (String (schemaId "config.schema.json")) $
      KM.insert "Version" version $
        withMinNodeVersion $
          KM.singleton "Configuration" (Object configuration)
 where
  -- Carry an existing Version, otherwise default to the current format (1).
  version = fromMaybe (Number 1) (KM.lookup "Version" top)
  -- Carry MinNodeVersion through if present; never invent one (it has no
  -- default, and its absence is itself a useful warning on the next parse).
  withMinNodeVersion = maybe id (KM.insert "MinNodeVersion") (KM.lookup "MinNodeVersion" top)

  -- The configuration body: an already-enveloped document's Configuration
  -- object, or (for a legacy\/non-enveloped document) the top-level object
  -- minus the envelope annotations.
  body = case KM.lookup "Configuration" top of
    Just (Object c) -> c
    _ -> KM.filterWithKey (\k _ -> K.toText k `notElem` envelopeAnnotations) top

  -- Group each body key under its component section. A flat property key nests
  -- under the section that owns it; a section key, HermodTracing or any
  -- unrecognised key stays at the Configuration level as-is. A mixed input (a
  -- section object plus some of its flat keys) is deep-merged.
  configuration = KM.foldrWithKey place KM.empty body
  place k v =
    case lookup (K.toText k) propertyToSection of
      Just section -> KM.insertWith mergeValues (K.fromText section) (Object (KM.singleton k v))
      Nothing -> KM.insertWith mergeValues k v
migrate v = v

-- | Top-level keys that belong to the envelope, not to the configuration body.
envelopeAnnotations :: [Text]
envelopeAnnotations = ["$schema", "Version", "MinNodeVersion", "Configuration"]

-- | Each component property name mapped to the section that owns it. Every
-- property belongs to exactly one component (see 'componentPropertyNames').
propertyToSection :: [(Text, Text)]
propertyToSection =
  [(prop, section) | (section, props) <- componentPropertyNames, prop <- props]
