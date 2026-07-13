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
--     absent; an existing @$schema@\/@Version@\/@MinNodeVersion@ is carried through
--     (so a pinned @$schema@ URL is not clobbered);
--   * a flat top-level property key is nested under the component section that
--     owns it (e.g. @ConsensusMode@ under @ConsensusConfig@, @LedgerDB@ under
--     @StorageConfig@);
--   * the flat tracing keys that @trace-dispatcher@'s own parser reads (its
--     legacy format: @TraceOptions@, @TraceOptionForwarder@, …) are gathered into
--     an inline @HermodTracing@ object, and the obsolete keys of the old
--     iohk-monitoring logging system (@setupScribes@, @minSeverity@, … — no longer
--     read by anything) are dropped (see 'tracingLegacyKeys'\/'tracingObsoleteKeys');
--   * a section key (whether an inline object or a path to a sub-file), an
--     existing @HermodTracing@ key, and any unrecognised key are kept at the
--     @Configuration@ level as-is (so nothing is silently dropped);
--   * a top-level sibling of an existing @Configuration@ envelope (e.g. a stray
--     @ByronGenesisFile@) is merged into the body and regrouped, not dropped; if it
--     collides with a key already inside @Configuration@ the enveloped value wins
--     and an 'EnvelopeKeyCollision' warning is raised;
--   * where both the old and the current name of a renamed field are present the
--     current name wins, with a 'RenamedKeyCollision' warning;
--   * a document already in the envelope is reshaped idempotently.
module Cardano.Configuration.File.Migrate
  ( migrate
  ) where

import Cardano.Configuration.File.Lint (ConfigWarning (..))
import Cardano.Configuration.File.Merge (mergeValues)
import Cardano.Configuration.Schema (componentPropertyNames, schemaId)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)

-- | Migrate a raw configuration value to the Version1 envelope, together with the
-- non-fatal 'ConfigWarning's raised while doing so (a renamed field colliding with
-- its current name, or a top-level sibling colliding with a key inside the
-- envelope). A value that is not a JSON\/YAML object is returned unchanged, with no
-- warnings.
--
-- Renames and removals are applied first (recursively, over the whole document)
-- so that the subsequent structural grouping sees only current names.
migrate :: Value -> (Value, [ConfigWarning])
migrate value =
  let (renamed, renameWarnings) = renameLegacy value
      (reshaped, reshapeWarnings) = reshape renamed
   in (reshaped, renameWarnings <> reshapeWarnings)

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
-- @PBftSignatureThreshold@ now come from consensus defaults rather than config;
-- @Protocol@ is the vestigial protocol selector; and @MaxKnownMajorProtocolVersion@
-- is a dead key the node never read at all. Unlike a genuine typo (which is kept,
-- so nothing is lost) these are known-obsolete keys, so @migrate@ removes them
-- rather than carry them forward as perpetual unrecognised-key warnings.
removedFields :: [Text]
removedFields =
  [ "PBftSignatureThreshold"
  , "LastKnownBlockVersion-Major"
  , "LastKnownBlockVersion-Minor"
  , "LastKnownBlockVersion-Alt"
  , "Protocol"
  , "MaxKnownMajorProtocolVersion"
  ]

-- | Rewrite renamed keys and drop removed keys, everywhere in the document,
-- accumulating a 'RenamedKeyCollision' warning wherever both the old and the
-- current name of a renamed field sit in the same object. Recurses through objects
-- and arrays; leaves scalars unchanged. The generic
-- 'acceptedConnectionsLimitFields' are rewritten only within an
-- @AcceptedConnectionsLimit@ object, not wherever those names happen to appear.
renameLegacy :: Value -> (Value, [ConfigWarning])
renameLegacy (Object o) =
  (Object (KM.fromList pairs), collisionWarnings <> concatMap snd rekeyed)
 where
  present = [K.toText k | (k, _) <- KM.toList o]
  -- A rename whose target already exists here: keep the (current-name) value that
  -- is already present, drop the old-name one, and warn. Without this, KM.fromList
  -- below would keep whichever the list order happened to put last.
  collisions = [(old, new) | (old, new) <- renamedFields, old `elem` present, new `elem` present]
  collidingOld = map fst collisions
  collisionWarnings = [RenamedKeyCollision old new | (old, new) <- collisions]

  -- The surviving entries (old names that collide are dropped, removed keys too),
  -- each recursed into and rekeyed.
  rekeyed =
    [ rekey (k, v)
    | (k, v) <- KM.toList o
    , K.toText k `notElem` removedFields
    , K.toText k `notElem` collidingOld
    ]
  pairs = map fst rekeyed
  rekey (k, v) = let (v', w) = renameLegacy v in ((rename renamedFields k, scoped k v'), w)
  -- Inside an AcceptedConnectionsLimit object, also rewrite its (generic) direct
  -- sub-keys; the recursion above has already handled any deeper nesting.
  scoped k v
    | K.toText k == "AcceptedConnectionsLimit" = renameTopKeys acceptedConnectionsLimitFields v
    | otherwise = v
renameLegacy (Array a) =
  let results = fmap renameLegacy a
   in (Array (fmap fst results), foldMap snd results)
renameLegacy v = (v, [])

-- | Apply a rename table to the direct keys of an object (only), leaving
-- non-objects and unlisted keys unchanged.
renameTopKeys :: [(Text, Text)] -> Value -> Value
renameTopKeys table (Object o) =
  Object (KM.fromList [(rename table k, v) | (k, v) <- KM.toList o])
renameTopKeys _ v = v

-- | Look a key up in a rename table, returning it unchanged if absent.
rename :: [(Text, Text)] -> K.Key -> K.Key
rename table k = maybe k K.fromText (lookup (K.toText k) table)

-- | The flat top-level tracing keys that @trace-dispatcher@'s own parser reads
-- directly (its \"legacy\" configuration format — see @parseAsLegacy@ in
-- @Cardano.Logging.ConfigurationParser@). These belong inside @HermodTracing@:
-- @migrate@ gathers them into an inline @HermodTracing@ object, which @resolve@
-- then hands to @trace-dispatcher@ verbatim. @TraceOptions@ is the only one the
-- parser requires; the rest are optional, but all are grouped when present.
tracingLegacyKeys :: [Text]
tracingLegacyKeys =
  [ "TraceOptions"
  , "TraceOptionForwarder"
  , "TraceOptionNodeName"
  , "TraceOptionMetricsPrefix"
  , "TraceOptionResourceFrequency"
  , "TraceOptionLedgerMetricsFrequency"
  , "TracePrometheusSimpleRun"
  ]

-- | The obsolete keys of the old iohk-monitoring\/katip logging system, fully
-- superseded by @trace-dispatcher@. Nothing reads them any more (not even the
-- @UseTraceDispatcher@ switch that once selected between the two systems), so
-- @migrate@ drops them. Unlike 'removedFields' these are dropped only at the top
-- level: their names (@options@, @minSeverity@) are too generic to remove
-- wherever they might appear at depth.
tracingObsoleteKeys :: [Text]
tracingObsoleteKeys =
  [ "UseTraceDispatcher"
  , "TurnOnLogging"
  , "TurnOnLogMetrics"
  , "defaultBackends"
  , "defaultScribes"
  , "setupBackends"
  , "setupScribes"
  , "minSeverity"
  , "options"
  ]

-- | The structural reshape into the Version1 envelope. A value that is not a
-- JSON\/YAML object is returned unchanged (with no warnings).
reshape :: Value -> (Value, [ConfigWarning])
reshape (Object top) =
  ( Object $
      KM.insert "$schema" schemaValue $
        KM.insert "Version" version $
          withMinNodeVersion $
            KM.singleton "Configuration" (Object configuration)
  , collisionWarnings
  )
 where
  -- Carry an existing $schema through (so a user's pinned schema URL survives),
  -- otherwise default to the published one on the main branch.
  schemaValue = fromMaybe (String (schemaId "config.schema.json")) (KM.lookup "$schema" top)
  -- Carry an existing Version, otherwise default to the current format (1).
  version = fromMaybe (Number 1) (KM.lookup "Version" top)
  -- Carry MinNodeVersion through if present; never invent one (it has no
  -- default, and its absence is itself a useful warning on the next parse).
  withMinNodeVersion = maybe id (KM.insert "MinNodeVersion") (KM.lookup "MinNodeVersion" top)

  -- The configuration body is the union of an already-enveloped document's
  -- Configuration object with the top-level keys that are not envelope
  -- annotations (a legacy\/non-enveloped document has no Configuration object, so
  -- the body is just those top-level keys). Nothing at the top level is dropped:
  -- a stray sibling such as @ByronGenesisFile@ is folded into the body and then
  -- regrouped under its section, rather than discarded.
  envelopeBody = case KM.lookup "Configuration" top of
    Just (Object c) -> c
    _ -> KM.empty
  siblings = KM.filterWithKey (\k _ -> K.toText k `notElem` envelopeAnnotations) top
  -- On a key present both as a sibling and inside Configuration, the value inside
  -- Configuration (the right\/\"later\" argument) wins; warn about the drop.
  body = KM.unionWith mergeValues siblings envelopeBody
  collisionWarnings =
    [EnvelopeKeyCollision (K.toText k) | k <- KM.keys siblings, k `KM.member` envelopeBody]

  -- Group each body key under its component section. A flat property key nests
  -- under the section that owns it; a flat trace-dispatcher key nests under
  -- HermodTracing; an obsolete iohk-monitoring key is dropped; a section key,
  -- an existing HermodTracing or any unrecognised key stays at the Configuration
  -- level as-is. A mixed input (a section object plus some of its flat keys, or
  -- HermodTracing alongside flat tracing keys) is deep-merged.
  configuration = KM.foldrWithKey place KM.empty body
  place k v
    | key `elem` tracingObsoleteKeys = id
    | key `elem` tracingLegacyKeys = nestUnder "HermodTracing"
    | Just section <- lookup key propertyToSection = nestUnder section
    | otherwise = keepFlat
   where
    key = K.toText k
    keepFlat = KM.insertWith mergeValues k v
    -- Nest a flat property under its target section, unless that section is
    -- already present as a non-object — a path to a sub-file. Merging an inline
    -- key into a file reference would silently drop the key (a file path is not an
    -- object, so 'mergeValues' would keep the path and lose the value), so in that
    -- case the property is kept at the Configuration level instead, where it
    -- surfaces as an unrecognised-key warning on the next parse rather than being
    -- lost. When the section is absent (a purely flat document) or an inline
    -- object, the property nests as normal.
    nestUnder section = case KM.lookup (K.fromText section) body of
      Just v' | not (isObject v') -> keepFlat
      _ -> KM.insertWith mergeValues (K.fromText section) (Object (KM.singleton k v))
    isObject Object{} = True
    isObject _ = False
reshape v = (v, [])

-- | Top-level keys that belong to the envelope, not to the configuration body.
envelopeAnnotations :: [Text]
envelopeAnnotations = ["$schema", "Version", "MinNodeVersion", "Configuration"]

-- | Each component property name mapped to the section that owns it. Every
-- property belongs to exactly one component (see 'componentPropertyNames').
propertyToSection :: [(Text, Text)]
propertyToSection =
  [(prop, section) | (section, props) <- componentPropertyNames, prop <- props]
