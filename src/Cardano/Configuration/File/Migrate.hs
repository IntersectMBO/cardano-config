-- | Reshape an existing configuration into the recommended Version1 envelope:
-- @{ $schema, Version, MinNodeVersion, Configuration }@, with every component
-- grouped under its section key inside @Configuration@.
--
-- It also rewrites the field names that changed, and drops the fields that were
-- removed, in the rename series that this library no longer parses (see
-- 'renamedFields'\/'removedFields'). This is deliberate: the parser rejects the
-- old names outright, and @migrate@ is the supported way to bring an older
-- configuration up to the current names.
--
-- Apart from those renames\/removals this is a purely structural migration: it
-- preserves the values as written and does /not/ fill in defaults, inline
-- referenced sub-files, or read genesis files. It is meant to port a legacy
-- single-file (flat) or otherwise non-enveloped configuration to the new layout;
-- resolution and validation are left to a subsequent @resolve@.
--
-- The reshaping (see 'migrate'):
--
--   * renamed keys are rewritten to their current names and removed keys are
--     dropped, at every depth (so the grouping below, which keys off the current
--     names, places them correctly);
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
--
-- Renames and removals are applied first (recursively, over the whole document)
-- so that the subsequent structural grouping sees only current names.
migrate :: Value -> Value
migrate = reshape . renameLegacy

-- | The field renames introduced in the current key-naming series, as
-- @(old, new)@. The parser only accepts the new names; @migrate@ rewrites the
-- old ones so a configuration written before the rename can be brought forward.
-- Matching is on the whole key (not a substring), so e.g.
-- @SyncTargetNumberOfRootPeers@ is left untouched by the @TargetNumberOf*@
-- entries. These names are globally unique, so they are rewritten at any depth;
-- the lower-cased 'acceptedConnectionsLimitFields' are handled separately
-- because those names are too generic to rewrite unconditionally.
renamedFields :: [(Text, Text)]
renamedFields =
  [ -- gRPC local-connection keys (were named Rpc)
    ("EnableRpc", "EnableGrpc")
  , ("RpcSocketPath", "GrpcSocketPath")
  , -- Deadline peer targets (gained the Deadline prefix)
    ("TargetNumberOfRootPeers", "DeadlineTargetNumberOfRootPeers")
  , ("TargetNumberOfKnownPeers", "DeadlineTargetNumberOfKnownPeers")
  , ("TargetNumberOfEstablishedPeers", "DeadlineTargetNumberOfEstablishedPeers")
  , ("TargetNumberOfActivePeers", "DeadlineTargetNumberOfActivePeers")
  , ("TargetNumberOfKnownBigLedgerPeers", "DeadlineTargetNumberOfKnownBigLedgerPeers")
  , ("TargetNumberOfEstablishedBigLedgerPeers", "DeadlineTargetNumberOfEstablishedBigLedgerPeers")
  , ("TargetNumberOfActiveBigLedgerPeers", "DeadlineTargetNumberOfActiveBigLedgerPeers")
  ]

-- | The @AcceptedConnectionsLimit@ sub-keys that were lower-cased before the
-- rename. Their names (@delay@ especially) are too generic to rewrite wherever
-- they appear, so they are only rewritten inside an @AcceptedConnectionsLimit@
-- object (see 'renameLegacy').
acceptedConnectionsLimitFields :: [(Text, Text)]
acceptedConnectionsLimitFields =
  [ ("hardLimit", "HardLimit")
  , ("softLimit", "SoftLimit")
  , ("delay", "Delay")
  ]

-- | The fields removed in the current series. @migrate@ drops them (they are no
-- longer parsed): the Byron @LastKnownBlockVersion-*@ trio and
-- @PBftSignatureThreshold@ now come from consensus defaults rather than config.
removedFields :: [Text]
removedFields =
  [ "PBftSignatureThreshold"
  , "LastKnownBlockVersion-Major"
  , "LastKnownBlockVersion-Minor"
  , "LastKnownBlockVersion-Alt"
  ]

-- | Rewrite renamed keys and drop removed keys, everywhere in the document.
-- Recurses through objects and arrays; leaves scalars unchanged. The generic
-- 'acceptedConnectionsLimitFields' are rewritten only within an
-- @AcceptedConnectionsLimit@ object, not wherever those names happen to appear.
renameLegacy :: Value -> Value
renameLegacy (Object o) =
  Object
    . KM.fromList
    . map rekey
    . filter (\(k, _) -> K.toText k `notElem` removedFields)
    $ KM.toList o
 where
  rekey (k, v) = (rename renamedFields k, scoped k (renameLegacy v))
  -- Inside an AcceptedConnectionsLimit object, also rewrite its (generic) direct
  -- sub-keys; the recursion above has already handled any deeper nesting.
  scoped k v
    | K.toText k == "AcceptedConnectionsLimit" = renameTopKeys acceptedConnectionsLimitFields v
    | otherwise = v
renameLegacy (Array a) = Array (fmap renameLegacy a)
renameLegacy v = v

-- | Apply a rename table to the direct keys of an object (only), leaving
-- non-objects and unlisted keys unchanged.
renameTopKeys :: [(Text, Text)] -> Value -> Value
renameTopKeys table (Object o) =
  Object (KM.fromList [(rename table k, v) | (k, v) <- KM.toList o])
renameTopKeys _ v = v

-- | Look a key up in a rename table, returning it unchanged if absent.
rename :: [(Text, Text)] -> K.Key -> K.Key
rename table k = maybe k K.fromText (lookup (K.toText k) table)

-- | The structural reshape into the Version1 envelope. A value that is not a
-- JSON\/YAML object is returned unchanged.
reshape :: Value -> Value
reshape (Object top) =
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
reshape v = v

-- | Top-level keys that belong to the envelope, not to the configuration body.
envelopeAnnotations :: [Text]
envelopeAnnotations = ["$schema", "Version", "MinNodeVersion", "Configuration"]

-- | Each component property name mapped to the section that owns it. Every
-- property belongs to exactly one component (see 'componentPropertyNames').
propertyToSection :: [(Text, Text)]
propertyToSection =
  [(prop, section) | (section, props) <- componentPropertyNames, prop <- props]
