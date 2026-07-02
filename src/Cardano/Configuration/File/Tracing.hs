-- | Tracing configuration.
--
-- Tracing is owned by the node's tracing system (hermod / @trace-dispatcher@),
-- not by @cardano-config@. The configuration is given under a single top-level
-- @HermodTracing@ key, whose value is /either/ a path (a string) to a separate
-- file holding the tracing configuration, /or/ that configuration object inline.
--
-- We do not interpret the tracing configuration ourselves: its authoritative
-- schema lives in @trace-dispatcher@. What we do is hand the @HermodTracing@
-- value to @trace-dispatcher@'s own parser ('readConfigurationWithDefault'), which turns it
-- into a 'TraceConfig' — a file reference via 'FromFile' (after resolving the
-- path to its canonical location), an inline object via 'FromJSONObject'.
--
-- Correspondingly, the configuration schema describes @HermodTracing@ only as
-- \"a path or a JSON object\"; the shape of that object is @trace-dispatcher@'s
-- responsibility to describe, not this library's.
module Cardano.Configuration.File.Tracing
  ( TracingConfiguration (..)
  , TracingConfigSource (..)
  , resolveTracingConfiguration
  , defaultCardanoTracingConfig
  ) where

import Autodocodec
import Cardano.Configuration.Basic (optionalFieldStrict)
import Cardano.Configuration.Common (filePathCodec)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Logging
import Data.Aeson (FromJSON, Object, ToJSON)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as Map
import GHC.Generics (Generic)
import System.Directory (canonicalizePath)
import System.FilePath ((</>))

-- | Where the @HermodTracing@ configuration comes from: either a path to a
-- separate file holding it, or the configuration object given inline. Which one
-- was written is decided purely by the JSON shape (a string vs. an object); the
-- contents are captured opaquely and only interpreted by @trace-dispatcher@.
data TracingConfigSource
  = -- | @HermodTracing@ was a path (a string) to a separate file.
    TracingConfigFile FilePath
  | -- | @HermodTracing@ held the tracing configuration object inline.
    TracingConfigInline Object
  deriving (Generic, Show)

-- | A single JSON string is read as a file path; a single JSON object is read as
-- an inline configuration. We dispatch on that shape (as 'NodeDatabasePaths'
-- does) so the two never compete in error messages.
instance HasCodec TracingConfigSource where
  codec =
    matchChoiceCodec
      (dimapCodec TracingConfigFile id filePathCodec)
      (dimapCodec TracingConfigInline id inlineObjectCodec)
      selector
   where
    selector (TracingConfigFile fp) = Left fp
    selector (TracingConfigInline o) = Right o

-- | A codec for an arbitrary JSON object. Its schema is just @type: object@ with
-- no described properties — this library deliberately says nothing about what
-- the tracing configuration object holds (that is @trace-dispatcher@'s domain).
inlineObjectCodec :: JSONCodec Object
inlineObjectCodec = dimapCodec KM.fromMapText KM.toMapText (mapCodec valueCodec)

-- | The tracing configuration is given under a single @HermodTracing@ key. It is
-- captured (as a path or an inline object) but not interpreted here; see the
-- module documentation and 'resolveTracingConfiguration'.
newtype TracingConfiguration = TracingConfiguration
  { hermodTracing :: StrictMaybe TracingConfigSource
  -- ^ The @HermodTracing@ value: a path to a file, or an inline object.
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via (Autodocodec TracingConfiguration)

instance HasCodec TracingConfiguration where
  codec =
    object "TracingConfiguration" $
      TracingConfiguration
        <$> optionalFieldStrict
          "HermodTracing"
          ( "Tracing configuration, given as a path to a separate file holding it "
              <> "or as that configuration object inline. Consumed by the node tracing "
              <> "system (trace-dispatcher), which owns its schema; not described further "
              <> "by cardano-config."
          )
          .= hermodTracing

-- | Resolve the captured @HermodTracing@ value into a 'TraceConfig' by handing it
-- to @trace-dispatcher@'s own parser ('readConfigurationWithDefault'), with
-- 'mkConfiguration' (the minimal viable config) supplying defaults for any
-- top-level fields the source leaves unspecified:
--
--   * a file reference is resolved to its canonical location (relative paths are
--     taken against the configuration directory @root@) and read via 'FromFile';
--   * an inline object is read via 'FromJSONObject'.
--
-- 'SNothing' when no @HermodTracing@ key is present.
resolveTracingConfiguration ::
  -- | The directory a relative @HermodTracing@ file path is resolved against.
  FilePath ->
  TracingConfiguration ->
  IO (StrictMaybe TraceConfig)
resolveTracingConfiguration root (TracingConfiguration mSource) =
  case mSource of
    SNothing -> pure SNothing
    SJust (TracingConfigFile path) -> do
      canonPath <- canonicalizePath (root </> path)
      SJust <$> readConfigurationWithDefault (FromFile canonPath) defaultCardanoTracingConfig
    SJust (TracingConfigInline obj) ->
      SJust <$> readConfigurationWithDefault (FromJSONObject obj) defaultCardanoTracingConfig

defaultCardanoTracingConfig :: TraceConfig
defaultCardanoTracingConfig =
  emptyTraceConfig
    { tcMetricsPrefix = Just "cardano.node.metrics."
    , tcLedgerMetricsFrequency = Nothing -- discard the default from 'trace-dispatcher'; Cardano has own ones, different for block producers and relays
    , tcOptions =
        Map.fromList
          [
            ( []
            ,
              [ ConfSeverity (SeverityF (Just Notice))
              , ConfDetail DNormal
              , ConfBackend
                  [ Stdout MachineFormat
                  , EKGBackend
                  ]
              ]
            )
          , -- more important tracers going here

            ( ["BlockFetch", "Decision"]
            , [ConfSeverity (SeverityF Nothing)]
            )
          ,
            ( ["ChainDB"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["ChainDB", "AddBlockEvent", "AddBlockValidation"]
            , [ConfSeverity (SeverityF Nothing)]
            )
          ,
            ( ["ChainSync", "Client"]
            , [ConfSeverity (SeverityF (Just Warning))]
            )
          ,
            ( ["Net", "ConnectionManager", "Remote"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["Startup", "DiffusionInit"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["Net", "ErrorPolicy"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["Forge", "Loop"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["Forge", "StateInfo"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["Net", "InboundGovernor", "Remote"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["Mempool"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["Net", "Mux", "Remote"]
            , [ConfSeverity (SeverityF (Just Info))]
            )
          ,
            ( ["Net", "InboundGovernor"]
            , [ConfSeverity (SeverityF (Just Warning))]
            )
          ,
            ( ["Net", "PeerSelection"]
            , [ConfSeverity (SeverityF Nothing)]
            )
          ,
            ( ["LedgerMetrics"]
            , [ConfSeverity (SeverityF Nothing)]
            )
          ,
            ( ["Resources"]
            , [ConfSeverity (SeverityF Nothing)]
            )
          , --     Limiters

            ( ["ChainDB", "AddBlockEvent", "AddedBlockToQueue"]
            , [ConfLimiter 2.0]
            )
          ,
            ( ["ChainDB", "AddBlockEvent", "AddedBlockToVolatileDB"]
            , [ConfLimiter 2.0]
            )
          ,
            ( ["ChainDB", "AddBlockEvent", "AddBlockValidation", "ValidCandidate"]
            , [ConfLimiter 2.0]
            )
          ,
            ( ["ChainDB", "CopyToImmutableDBEvent", "CopiedBlockToImmutableDB"]
            , [ConfLimiter 2.0]
            )
          ,
            ( ["BlockFetch", "Client", "CompletedBlockFetch"]
            , [ConfLimiter 2.0]
            )
          ]
    }
