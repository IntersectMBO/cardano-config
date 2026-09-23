-- | Orchestration of configuration-file parsing: it ties together the JSON
-- layering engine ("Cardano.Configuration.File.Merge"), the key linting
-- ("Cardano.Configuration.File.Lint") and the per-component parsers and genesis
-- readers, and re-exports the public surface.
module Cardano.Configuration.File
  ( -- * Configuration file
    NodeConfigurationFromFile (..)
  , parseConfigurationFiles

    -- * Warnings
  , ConfigWarning (..)
  , renderConfigWarning

    -- * Defaults
  , componentDefaults

    -- * Errors
  , ConfigurationParsingError (..)

    -- * Specific components configurations
  , StorageConfiguration (..)
  , ConsensusConfiguration (..)
  , ProtocolConfiguration (..)
  , NetworkConfiguration (..)
  , DiffusionMode (..)
  , AcceptedConnectionsLimit (..)
  , LocalConnectionsConfig (..)
  , GrpcEndpoint (..)
  , GrpcTlsFiles (..)
  , defaultGrpcListenAddress
  , TestingConfiguration (..)
  , MempoolConfiguration (..)
  , TracingConfiguration (..)
  , TracingConfigSource (..)
  , TraceConfig
  , defaultCardanoTracingConfig

    -- * Resolving components
  , finalizeNetwork
  , finalizeLocalConnections
  , finalizeMempool
  , finalizeTesting

    -- * Network role defaults
  , BlockProducerOrRelay (..)
  , withRoleDefaults
  , networkRoleDefaults
  , blockProducerRoleDefaults
  , relayRoleDefaults
  , emptyNetworkConfiguration
  ) where

import Cardano.Configuration.File.Consensus
import Cardano.Configuration.File.Error (ConfigurationParsingError (..))
import Cardano.Configuration.File.Lint
  ( ConfigWarning (..)
  , configWarnings
  , renderConfigWarning
  )
import Cardano.Configuration.File.Mempool
import Cardano.Configuration.File.Merge
  ( declaredFormatVersion
  , decodeValueFile
  , loadBaseDefault
  , parseSection
  , runCodec
  , sectionUserLayer
  , splitEnvelope
  )
import Cardano.Configuration.File.Migrate (migrate, renderMigrationError)
import Cardano.Configuration.File.Network
import Cardano.Configuration.File.Protocol
import Cardano.Configuration.File.Storage
import Cardano.Configuration.File.Testing
import Cardano.Configuration.File.Tracing
  ( TracingConfigSource (..)
  , TracingConfiguration (..)
  , defaultCardanoTracingConfig
  , resolveTracingConfiguration
  )
import Cardano.Configuration.Genesis
  ( GenesisReadError
  , genesisErrorFile
  , readGenesisFile
  , resolveExperimentalGenesis
  )
import Cardano.Configuration.Genesis.Byron (ByronGenesisConfig, readByronGenesisConfig)
import Cardano.Configuration.Genesis.Injection
  ( InjectionSlot (..)
  , injectionProblems
  , injectionSlots
  , missingInjectionFiles
  , renderInjectionSlot
  )
import Cardano.Configuration.Schema (componentPropertyNames, currentFormatVersion)
import qualified Cardano.Crypto.ProtocolMagic as Byron
import Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis)
import Cardano.Ledger.BaseTypes
  ( StrictMaybe (..)
  , fromSMaybe
  , maybeToStrictMaybe
  , strictMaybeToMaybe
  )
import Cardano.Ledger.Conway.Genesis (ConwayGenesis)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis)
import Cardano.Ledger.Shelley.Genesis (ShelleyGenesis)
import Cardano.Logging.Types (TraceConfig)
import Control.Exception (throwIO)
import Control.Monad (when)
import Data.Aeson (FromJSON, Value)
import qualified Data.Aeson.Key as K
import Data.Aeson.Types (JSONPathElement (..))
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import GHC.Generics (Generic)
import GHC.Stack
import System.FilePath (takeDirectory, (</>))

-- | The fully parsed configuration, as read from the configuration file with
-- 'parseConfigurationFiles'.
--
-- Each component is the merge of its base default with the section the user
-- wrote, so its own @f@ parameter is 'StrictMaybe': a field the configuration
-- leaves unset is @SNothing@ here and is filled at resolution, from the command
-- line or as an error (see 'Cardano.Configuration.resolveConfiguration').
data NodeConfigurationFromFile = NodeConfigurationFromFile
  { minNodeVersion :: StrictMaybe T.Text
  -- ^ The minimum @cardano-node@ version expected to run this configuration,
  -- taken from the optional top-level @MinNodeVersion@ key (a sibling of
  -- @Version@, present in both the enveloped and legacy forms). Purely
  -- informational here — it is recorded for a consumer to check.
  --
  -- Caveat: this is /not/ carried into the resolved
  -- t'Cardano.Configuration.NodeConfiguration'; 'resolveConfiguration' drops it.
  -- It lives only on this file-parse result, so a consumer that wants to act on
  -- it must read it here, before resolving.
  , storageConfiguration :: StorageConfiguration StrictMaybe
  , consensusConfiguration :: ConsensusConfiguration StrictMaybe
  , protocolConfiguration :: ProtocolConfiguration StrictMaybe
  , networkConfiguration :: NetworkConfiguration StrictMaybe
  , networkUserLayer :: NetworkConfiguration StrictMaybe
  -- ^ The user-supplied network layer alone, /without/ the base defaults merged
  -- in (unlike 'networkConfiguration', which is the full merge of the base
  -- defaults with the user layer on top).
  --
  -- Resolution needs to tell a value the user actually wrote from one that only
  -- came from the base defaults, so the role defaults can sit between them
  -- (@base \< role \< user@); see 'withRoleDefaults'.
  , localConnectionsConfig :: LocalConnectionsConfig StrictMaybe
  , testingConfiguration :: TestingConfiguration StrictMaybe
  , mempoolConfiguration :: MempoolConfiguration StrictMaybe
  , tracingConfiguration :: TraceConfig
  -- ^ The tracing configuration referenced by the top-level @HermodTracing@ key,
  -- resolved by @trace-dispatcher@'s own parser ('resolveTracingConfiguration'):
  -- a @HermodTracing@ file path is read from that file, an inline object is read
  -- directly. When no @HermodTracing@ key is present it falls back to
  -- 'defaultCardanoTracingConfig', so a tracing configuration is always present.
  -- Its schema is owned by @trace-dispatcher@, not described here (see
  -- 'TracingConfiguration').
  , byronGenesisConfig :: ByronGenesisConfig
  -- ^ The parsed Byron genesis (read from the @ByronGenesisFile@).
  , shelleyGenesisConfig :: ShelleyGenesis
  -- ^ The parsed Shelley genesis (read from the @ShelleyGenesisFile@).
  , alonzoGenesisConfig :: AlonzoGenesis
  -- ^ The parsed Alonzo genesis (read from the @AlonzoGenesisFile@).
  , conwayGenesisConfig :: ConwayGenesis
  -- ^ The parsed Conway genesis (read from the @ConwayGenesisFile@).
  , experimentalGenesisConfig :: StrictMaybe DijkstraGenesis
  -- ^ The experimental (Dijkstra) genesis, when there is one in play.
  , genesisInjectionRoot :: FilePath
  -- ^ The directory the ledger resolves genesis initial-data injection files
  -- against: the directory holding the Shelley genesis file (which is /not/ in
  -- general the directory holding the configuration file).
  --
  -- A genesis @extraConfig@ names its injection files by @FsPath@ — a list of
  -- path segments resolved against a @HasFS@ the consumer supplies — so the
  -- mount point is the configuration's to decide. Recording it here means a
  -- consumer building the node's @SomeHasFS@ does not have to re-derive it; see
  -- "Cardano.Configuration.Genesis.Injection".
  }
  deriving (Generic, Show)

-- | The per-component base defaults (@defaults\/<Component>.json@), for schema
-- generation. Keyed by component name; components without a defaults file are
-- omitted. These are the same files the resolver merges as the base layer, so
-- the documented defaults match the applied ones.
componentDefaults :: IO [(T.Text, Value)]
componentDefaults =
  catMaybes
    <$> mapM
      (\name -> fmap (name,) <$> loadBaseDefault (T.unpack name))
      (map fst componentPropertyNames)

-- | Parse the configuration file, together with any non-fatal
-- 'ConfigWarning's (unrecognised keys, or a document that had to be migrated).
--
-- The whole configuration is held in that one file, apart from the genesis
-- files and the optional @HermodTracing@ file, which are read from the paths it
-- gives.
--
-- The configuration may be given in JSON or YAML. Failures are thrown as a
-- 'ConfigurationParsingError', identifying the offending file, section and
-- location. The warnings are /returned/, not emitted: the caller decides whether
-- to print them, log them, or treat them as fatal (see 'renderConfigWarning').
parseConfigurationFiles ::
  HasCallStack => FilePath -> IO (NodeConfigurationFromFile, [ConfigWarning])
parseConfigurationFiles cfgFile = do
  rawValue <- decodeValueFile cfgFile
  -- Every document is run through 'migrate' before parsing, so an already-enveloped
  -- configuration that still uses a pre-rename field name (or carries a stray
  -- top-level sibling) is brought up to the current shape too — not only a
  -- non-enveloped one. Migration is idempotent, so a configuration already in the
  -- canonical form is left untouched; a 'MigratedToCurrentFormat' warning is raised
  -- only when migration actually changed the document (@migrated /= rawValue@, an
  -- order-independent comparison). 'migrate' also returns its own warnings for the
  -- fields it had to reconcile. If the migrated document still cannot be parsed, the
  -- parse error surfaces as usual.
  -- The declared version is read before migrating, because migrating rewrites
  -- it. A version this library does not write is rejected here rather than
  -- misread as the current one.
  declared <- declaredFormatVersion rawValue
  when (declared > currentFormatVersion) $
    throwIO $
      ConfigurationParsingError
        (SJust cfgFile)
        SNothing
        [Key "Version"]
        ( "unsupported configuration version: "
            <> show declared
            <> ". This cardano-config writes version "
            <> show currentFormatVersion
            <> ", so upgrade cardano-config to read it."
        )
  -- A document migrate cannot reshape — one whose sections name separate files
  -- rather than holding their configuration — is rejected here, naming them.
  (mainValue, migrateWarnings) <- case migrate rawValue of
    Left err ->
      throwIO $
        ConfigurationParsingError (SJust cfgFile) SNothing [] (renderMigrationError err)
    Right ok -> pure ok
  let migrationWarnings =
        -- An outdated version is reported on its own. migrate always rewrites
        -- such a document, so the generic warning would only repeat it.
        [ MigratedToCurrentFormat
        | mainValue /= rawValue
        , declared == currentFormatVersion
        ]
          <> [OutdatedFormatVersion declared currentFormatVersion | declared < currentFormatVersion]
          <> migrateWarnings
  -- migrate has brought the document to the current version, so there is one
  -- body parser rather than one per version.
  (_version, minNodeVer, configValue) <- splitEnvelope mainValue
  let warnings = migrationWarnings <> configWarnings configValue
      root = takeDirectory cfgFile
  (config, parseWarnings) <- parseConfigurationBody root minNodeVer configValue
  pure (config, warnings <> parseWarnings)

-- | Parse a configuration object at the current format version, reading each
-- component from its inline section, together with the warnings that only the
-- parsed configuration can reveal (an ignored experimental genesis).
parseConfigurationBody ::
  -- | The directory the genesis and tracing paths are resolved against.
  FilePath ->
  -- | The optional top-level @MinNodeVersion@ annotation.
  Maybe T.Text ->
  -- | The configuration object.
  Value ->
  IO (NodeConfigurationFromFile, [ConfigWarning])
parseConfigurationBody root minNodeVer configValue = do
  storage <- parseSection configValue "StorageConfig"
  consensus <- parseSection configValue "ConsensusConfig"
  protocol <- parseSection configValue "ProtocolConfig"
  network <- parseSection configValue "NetworkConfig"
  -- The user's network layer on its own (no base defaults), so resolution can
  -- distinguish a user-set field from a base default (see 'withRoleDefaults').
  networkUser <-
    sectionUserLayer configValue "NetworkConfig" >>= runCodec "NetworkConfig"
  localConnections <- parseSection configValue "LocalConnectionsConfig"
  testing <- parseSection configValue "TestingConfig"
  mempool <- parseSection configValue "MempoolConfig"
  -- The @HermodTracing@ value is captured (as a file path or an inline object)
  -- and then handed to trace-dispatcher's own parser, which resolves it to a
  -- 'TraceConfig' — reading the referenced file, or the inline object directly.
  tracing <- runCodec "Tracing" configValue
  traceConfig <- resolveTracingConfiguration root tracing
  -- The genesis files referenced by the configuration are read and decoded
  -- here, so that JSON resolution happens entirely within this library.
  let byronCfg = byronGenesis protocol
  byronGenesisData <-
    readByronGenesisOrThrow
      root
      (toByronReqNetworkMagic (byronReqNetworkMagic byronCfg))
      (byronGenesisFile byronCfg)
  shelleyGenesisData <-
    readEraGenesisOrThrow root "ShelleyGenesisFile" (shelleyGenesis protocol)
  -- The injection files a genesis @extraConfig@ references are resolved by the
  -- ledger against the Shelley genesis directory, so that is the root recorded
  -- (and checked) here — see "Cardano.Configuration.Genesis.Injection".
  let injectionRoot = takeDirectory (root </> hashed (shelleyGenesis protocol))
  alonzoGenesisData <-
    readEraGenesisOrThrow root "AlonzoGenesisFile" (alonzoGenesis protocol)
  conwayGenesisData <-
    readEraGenesisOrThrow root "ConwayGenesisFile" (conwayGenesis protocol)
  -- The experimental (Dijkstra) genesis is gated on the
  -- @ExperimentalHardForksEnabled@ testing flag.
  let experimentalRef = strictMaybeToMaybe (experimentalGenesis testing)
      experimentalEnabled = fromSMaybe False (experimentalHardForksEnabled testing)
  experimentalGenesisData <-
    if experimentalEnabled
      then readExperimentalGenesisOrThrow root experimentalRef
      else pure Nothing
  let experimentalWarnings =
        [ ExperimentalGenesisIgnored file
        | not experimentalEnabled
        , Hashed file _ <- maybe [] pure experimentalRef
        ]
  checkInjectionOrThrow injectionRoot shelleyGenesisData conwayGenesisData
  pure . (,experimentalWarnings) $
    NodeConfigurationFromFile
      { minNodeVersion = maybeToStrictMaybe minNodeVer
      , storageConfiguration = storage
      , consensusConfiguration = consensus
      , protocolConfiguration = protocol
      , networkConfiguration = network
      , networkUserLayer = networkUser
      , localConnectionsConfig = localConnections
      , testingConfiguration = testing
      , mempoolConfiguration = mempool
      , tracingConfiguration = traceConfig
      , byronGenesisConfig = byronGenesisData
      , shelleyGenesisConfig = shelleyGenesisData
      , alonzoGenesisConfig = alonzoGenesisData
      , conwayGenesisConfig = conwayGenesisData
      , experimentalGenesisConfig = maybeToStrictMaybe experimentalGenesisData
      , genesisInjectionRoot = injectionRoot
      }

-- | Convert this library's 'RequiresNetworkMagic' to the Byron ledger's, used
-- when reading the Byron genesis. Absent in the configuration defaults to
-- requiring no magic.
toByronReqNetworkMagic :: StrictMaybe RequiresNetworkMagic -> Byron.RequiresNetworkMagic
toByronReqNetworkMagic = \case
  SJust RequiresMagic -> Byron.RequiresMagic
  SJust RequiresNoMagic -> Byron.RequiresNoMagic
  SNothing -> Byron.RequiresNoMagic

-- | Read, hash-check and decode an (aeson) era genesis file referenced by the
-- protocol configuration, throwing a 'ConfigurationParsingError' on failure.
readEraGenesisOrThrow ::
  FromJSON a => FilePath -> String -> Hashed FilePath -> IO a
readEraGenesisOrThrow root fileKey (Hashed file mHash) = do
  result <- readGenesisFile mHash (root </> file)
  case result of
    Left err -> throwIO (genesisReadErrorAt "ProtocolConfig" fileKey err)
    Right genesis -> pure genesis

-- | Read, hash-check and decode the Byron genesis (canonical JSON), throwing a
-- 'ConfigurationParsingError' on failure.
readByronGenesisOrThrow ::
  FilePath -> Byron.RequiresNetworkMagic -> Hashed FilePath -> IO ByronGenesisConfig
readByronGenesisOrThrow root rnm (Hashed file expected) = do
  result <- readByronGenesisConfig rnm expected (root </> file)
  case result of
    Left err ->
      throwIO $
        ConfigurationParsingError
          (SJust (root </> file))
          (SJust "ProtocolConfig")
          [Key "ByronGenesisFile"]
          err
    Right cfg -> pure cfg

-- | Read and decode the experimental (Dijkstra) genesis referenced by the
-- testing configuration, turning a read\/hash\/decode failure into a
-- 'ConfigurationParsingError' under the @TestingConfig@ section.
--
-- Whether to read it at all is the caller's decision: it is called only when
-- @ExperimentalHardForksEnabled@ is on (see 'experimentalGenesisConfig').
readExperimentalGenesisOrThrow ::
  FilePath -> Maybe (Hashed FilePath) -> IO (Maybe DijkstraGenesis)
readExperimentalGenesisOrThrow root mRef = do
  result <- resolveExperimentalGenesis root mRef
  case result of
    Left err -> throwIO (genesisReadErrorAt "TestingConfig" "DijkstraGenesisFile" err)
    Right genesis -> pure genesis

-- | Check the genesis initial-data injection the geneses ask for, throwing a
-- 'ConfigurationParsingError' attributed to the genesis key at fault: a field
-- must name one source, not both the legacy field and its @extraConfig@
-- counterpart; injection is for test networks only; and a referenced injection
-- file must exist.
--
-- The files' hashes are /not/ checked: the ledger verifies them as it streams
-- each file, and re-hashing here would mean reading a potentially very large
-- file twice. Everything checked here is something @cardano-ledger@ would
-- otherwise throw much later, while the node builds its initial ledger state.
checkInjectionOrThrow :: FilePath -> ShelleyGenesis -> ConwayGenesis -> IO ()
checkInjectionOrThrow injectionRoot sg cg = do
  missing <- missingInjectionFiles injectionRoot (injectionSlots sg cg)
  let problems =
        injectionProblems sg cg
          <> [ (s, "references the injection file " <> path <> ", which does not exist")
             | (s, path) <- missing
             ]
  case problems of
    [] -> pure ()
    (slot, why) : _ ->
      throwIO $
        ConfigurationParsingError
          SNothing
          (SJust "ProtocolConfig")
          [Key (K.fromString (slotGenesisFile slot))]
          (renderInjectionSlot slot <> " " <> why)

-- | Render a 'GenesisReadError' as a 'ConfigurationParsingError' attributed to
-- the given section and file key.
genesisReadErrorAt :: String -> String -> GenesisReadError -> ConfigurationParsingError
genesisReadErrorAt section fileKey err =
  ConfigurationParsingError
    (maybeToStrictMaybe (genesisErrorFile err))
    (SJust section)
    [Key (K.fromString fileKey)]
    (show err)
