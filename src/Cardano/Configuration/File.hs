{-# LANGUAGE GADTs #-}

-- | Orchestration of configuration-file parsing: it ties together the JSON
-- layering engine ("Cardano.Configuration.File.Merge"), the key linting
-- ("Cardano.Configuration.File.Lint") and the per-component parsers and genesis
-- readers, and re-exports the public surface.
module Cardano.Configuration.File
  ( -- * Configuration file
    NodeConfigurationFromFile
  , NodeConfigurationFromFileF (..)
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
  , inVersion1Format
  , renderConfigWarning
  )
import Cardano.Configuration.File.Mempool
import Cardano.Configuration.File.Merge
  ( decodeValueFile
  , loadBaseDefault
  , parseSection
  , runCodec
  , sectionUserLayer
  , splitEnvelope
  )
import Cardano.Configuration.File.Migrate (migrate)
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
import Cardano.Configuration.Schema (componentPropertyNames)
import qualified Cardano.Crypto.ProtocolMagic as Byron
import Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), maybeToStrictMaybe, strictMaybeToMaybe)
import Cardano.Ledger.Conway.Genesis (ConwayGenesis)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis)
import Cardano.Ledger.Shelley.Genesis (ShelleyGenesis)
import Cardano.Logging.Types (TraceConfig)
import Control.Exception (throwIO)
import Data.Aeson (FromJSON, Value)
import qualified Data.Aeson.Key as K
import Data.Aeson.Types (JSONPathElement (..))
import Data.Functor.Identity (Identity (..))
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import GHC.Generics (Generic)
import GHC.Stack
import System.FilePath (takeDirectory, (</>))

-- | The configuration from the files, parsed with 'parseConfigurationFiles'
type NodeConfigurationFromFile = NodeConfigurationFromFileF Identity

-- | The configuration from the files, initially maybe pointing to sub-files and
-- finally fully parsed.
data NodeConfigurationFromFileF f
  = NodeConfigurationFromFileV1
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
  , storageConfiguration :: f (StorageConfiguration StrictMaybe)
  , consensusConfiguration :: f (ConsensusConfiguration StrictMaybe)
  , protocolConfiguration :: f (ProtocolConfiguration StrictMaybe)
  , networkConfiguration :: f (NetworkConfiguration StrictMaybe)
  , networkUserLayer :: f (NetworkConfiguration StrictMaybe)
  -- ^ The user-supplied network layer alone, /without/ the base defaults merged
  -- in (unlike 'networkConfiguration', which is the full merge of the base
  -- defaults with the user layer on top).
  --
  -- Resolution needs to tell a value the user actually wrote from one that only
  -- came from the base defaults, so the role defaults can sit between them
  -- (@base \< role \< user@); see 'withRoleDefaults'.
  , localConnectionsConfig :: f (LocalConnectionsConfig StrictMaybe)
  , testingConfiguration :: f (TestingConfiguration StrictMaybe)
  , mempoolConfiguration :: f (MempoolConfiguration StrictMaybe)
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
  -- ^ The experimental (Dijkstra) genesis, read and decoded from the
  -- @DijkstraGenesisFile@ referenced by the testing configuration (if any).
  --
  -- These are the parsed genesis values, not file paths — all genesis JSON
  -- resolution happens here.
  }
  deriving Generic

deriving instance Show (NodeConfigurationFromFileF Identity)

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

-- | Parse the configuration file and any sub-files referenced from it, together
-- with any non-fatal 'ConfigWarning's (unrecognised keys, shadowed keys, use of
-- the legacy single-file form).
--
-- The configuration may be given in JSON or YAML. Failures are thrown as a
-- 'ConfigurationParsingError', identifying the offending file, section and
-- location. The warnings are /returned/, not emitted: the caller decides whether
-- to print them, log them, or treat them as fatal (see 'renderConfigWarning').
parseConfigurationFiles ::
  HasCallStack => FilePath -> IO (NodeConfigurationFromFile, [ConfigWarning])
parseConfigurationFiles cfgFile = do
  rawValue <- decodeValueFile Nothing cfgFile
  -- The parser accepts only the Version1 format (a top-level @Configuration@
  -- envelope). A document that is not in it is not parsed as-is: it is migrated
  -- to the Version1 format first — with a 'MigratedToVersion1' warning — and the
  -- result is parsed. If that migrated document still cannot be parsed, the parse
  -- error surfaces as usual (so a non-Version1 document whose migration does not
  -- yield a parseable configuration is rejected).
  let (mainValue, migrationWarnings) =
        if inVersion1Format rawValue
          then (rawValue, [])
          else (migrate rawValue, [MigratedToVersion1])
  (version, minNodeVer, configValue) <- splitEnvelope mainValue
  let warnings = migrationWarnings <> configWarnings configValue
      root = takeDirectory cfgFile
  config <- case version of
    1 -> parseConfigurationVersion1 root minNodeVer configValue
    n ->
      throwIO $
        ConfigurationParsingError
          (SJust cfgFile)
          SNothing
          [Key "Version"]
          ("unsupported configuration version: " <> show n)
  pure (config, warnings)

-- | Parse a version-1 configuration object, reading each component either
-- inline or from its referenced sub-file.
parseConfigurationVersion1 ::
  -- | The directory sub-file paths are resolved against.
  FilePath ->
  -- | The optional top-level @MinNodeVersion@ annotation.
  Maybe T.Text ->
  -- | The configuration object.
  Value ->
  IO NodeConfigurationFromFile
parseConfigurationVersion1 root minNodeVer configValue = do
  storage <- parseSection root configValue "StorageConfig"
  consensus <- parseSection root configValue "ConsensusConfig"
  protocol <- parseSection root configValue "ProtocolConfig"
  network <- parseSection root configValue "NetworkConfig"
  -- The user's network layer on its own (no base defaults), so resolution can
  -- distinguish a user-set field from a base default (see 'withRoleDefaults').
  networkUser <-
    sectionUserLayer root configValue "NetworkConfig" >>= runCodec Nothing "NetworkConfig"
  localConnections <- parseSection root configValue "LocalConnectionsConfig"
  testing <- parseSection root configValue "TestingConfig"
  mempool <- parseSection root configValue "MempoolConfig"
  -- The @HermodTracing@ value is captured (as a file path or an inline object)
  -- and then handed to trace-dispatcher's own parser, which resolves it to a
  -- 'TraceConfig' — reading the referenced file, or the inline object directly.
  tracing <- runCodec Nothing "Tracing" configValue
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
  alonzoGenesisData <-
    readEraGenesisOrThrow root "AlonzoGenesisFile" (alonzoGenesis protocol)
  conwayGenesisData <-
    readEraGenesisOrThrow root "ConwayGenesisFile" (conwayGenesis protocol)
  experimentalGenesisData <-
    readExperimentalGenesisOrThrow root (strictMaybeToMaybe (experimentalGenesis testing))
  pure
    NodeConfigurationFromFileV1
      { minNodeVersion = maybeToStrictMaybe minNodeVer
      , storageConfiguration = Identity storage
      , consensusConfiguration = Identity consensus
      , protocolConfiguration = Identity protocol
      , networkConfiguration = Identity network
      , networkUserLayer = Identity networkUser
      , localConnectionsConfig = Identity localConnections
      , testingConfiguration = Identity testing
      , mempoolConfiguration = Identity mempool
      , tracingConfiguration = traceConfig
      , byronGenesisConfig = byronGenesisData
      , shelleyGenesisConfig = shelleyGenesisData
      , alonzoGenesisConfig = alonzoGenesisData
      , conwayGenesisConfig = conwayGenesisData
      , experimentalGenesisConfig = maybeToStrictMaybe experimentalGenesisData
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
readExperimentalGenesisOrThrow ::
  FilePath -> Maybe (Hashed FilePath) -> IO (Maybe DijkstraGenesis)
readExperimentalGenesisOrThrow root mRef = do
  result <- resolveExperimentalGenesis root mRef
  case result of
    Left err -> throwIO (genesisReadErrorAt "TestingConfig" "DijkstraGenesisFile" err)
    Right genesis -> pure genesis

-- | Render a 'GenesisReadError' as a 'ConfigurationParsingError' attributed to
-- the given section and file key.
genesisReadErrorAt :: String -> String -> GenesisReadError -> ConfigurationParsingError
genesisReadErrorAt section fileKey err =
  ConfigurationParsingError
    (maybeToStrictMaybe (genesisErrorFile err))
    (SJust section)
    [Key (K.fromString fileKey)]
    (show err)
