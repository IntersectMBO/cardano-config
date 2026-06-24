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
  ) where

import Autodocodec (JSONCodec)
import Cardano.Configuration.File.Consensus
import Cardano.Configuration.File.Error (ConfigurationParsingError (..))
import Cardano.Configuration.File.Lint
  ( ConfigWarning (..)
  , configWarnings
  , renderConfigWarning
  )
import Cardano.Configuration.File.Mempool
import Cardano.Configuration.File.Merge
  ( decodeValueFile
  , loadBaseDefault
  , parseSection
  , runCodec
  , splitEnvelope
  )
import Cardano.Configuration.File.Network
import Cardano.Configuration.File.Protocol
import Cardano.Configuration.File.Storage
import Cardano.Configuration.File.Testing
import Cardano.Configuration.File.Tracing
import Cardano.Configuration.Genesis
  ( GenesisReadError
  , genesisErrorFile
  , readGenesisFileWith
  , resolveExperimentalGenesis
  )
import Cardano.Configuration.Genesis.Alonzo (alonzoGenesisCodec)
import Cardano.Configuration.Genesis.Byron (ByronGenesisConfig, readByronGenesisConfig)
import Cardano.Configuration.Genesis.Conway (conwayGenesisCodec)
import Cardano.Configuration.Genesis.Shelley (shelleyGenesisCodec)
import Cardano.Configuration.Schema (componentPropertyNames)
import qualified Cardano.Crypto.ProtocolMagic as Byron
import Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis)
import Cardano.Ledger.Conway.Genesis (ConwayGenesis)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis)
import Cardano.Ledger.Shelley.Genesis (ShelleyGenesis)
import Control.Exception (throwIO)
import Data.Aeson (Value)
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
  { storageConfiguration :: f (StorageConfiguration Maybe)
  , consensusConfiguration :: f (ConsensusConfiguration Maybe)
  , protocolConfiguration :: f (ProtocolConfiguration Maybe)
  , networkConfiguration :: f (NetworkConfiguration Maybe)
  , localConnectionsConfig :: f (LocalConnectionsConfig Maybe)
  , testingConfiguration :: f (TestingConfiguration Maybe)
  , mempoolConfiguration :: f (MempoolConfiguration Maybe)
  , tracingConfiguration :: TracingConfiguration
  -- ^ Tracing keys, captured opaquely; see 'TracingConfiguration'. Unlike the
  --     other components this is never read from a sub-file: the node's tracing
  --     system resolves its own @HermodTracing@ file indirection.
  , byronGenesisConfig :: ByronGenesisConfig
  -- ^ The parsed Byron genesis (read from the @ByronGenesisFile@).
  , shelleyGenesisConfig :: ShelleyGenesis
  -- ^ The parsed Shelley genesis (read from the @ShelleyGenesisFile@).
  , alonzoGenesisConfig :: AlonzoGenesis
  -- ^ The parsed Alonzo genesis (read from the @AlonzoGenesisFile@).
  , conwayGenesisConfig :: ConwayGenesis
  -- ^ The parsed Conway genesis (read from the @ConwayGenesisFile@).
  , experimentalGenesisConfig :: Maybe DijkstraGenesis
  -- ^ The experimental (Dijkstra) genesis, read and decoded from the
  --     @DijkstraGenesisFile@ referenced by the testing configuration (if any).
  --
  --     These are the parsed genesis values, not file paths — all genesis JSON
  --     resolution happens here.
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
  mainValue <- decodeValueFile Nothing cfgFile
  (version, configValue) <- splitEnvelope mainValue
  let warnings = configWarnings configValue
      root = takeDirectory cfgFile
  config <- case version of
    1 -> parseConfigurationVersion1 root configValue
    n ->
      throwIO $
        ConfigurationParsingError
          (Just cfgFile)
          Nothing
          [Key "Version"]
          ("unsupported configuration version: " <> show n)
  pure (config, warnings)

-- | Parse a version-1 configuration object, reading each component either
-- inline or from its referenced sub-file.
parseConfigurationVersion1 ::
  -- | The directory sub-file paths are resolved against.
  FilePath ->
  -- | The configuration object.
  Value ->
  IO NodeConfigurationFromFile
parseConfigurationVersion1 root configValue = do
  storage <- parseSection root configValue "StorageConfig"
  consensus <- parseSection root configValue "ConsensusConfig"
  protocol <- parseSection root configValue "ProtocolConfig"
  network <- parseSection root configValue "NetworkConfig"
  localConnections <- parseSection root configValue "LocalConnectionsConfig"
  testing <- parseSection root configValue "TestingConfig"
  mempool <- parseSection root configValue "MempoolConfig"
  tracing <- runCodec Nothing "Tracing" configValue
  -- The genesis files referenced by the configuration are read and decoded
  -- here, so that JSON resolution happens entirely within this library.
  let byronCfg = byronGenesis protocol
  byronGenesisData <-
    readByronGenesisOrThrow
      root
      (toByronReqNetworkMagic (byronReqNetworkMagic byronCfg))
      (byronGenesisFile byronCfg)
  shelleyGenesisData <-
    readEraGenesisOrThrow shelleyGenesisCodec root "ShelleyGenesisFile" (shelleyGenesis protocol)
  alonzoGenesisData <-
    readEraGenesisOrThrow alonzoGenesisCodec root "AlonzoGenesisFile" (alonzoGenesis protocol)
  conwayGenesisData <-
    readEraGenesisOrThrow conwayGenesisCodec root "ConwayGenesisFile" (conwayGenesis protocol)
  experimentalGenesisData <- readExperimentalGenesisOrThrow root (experimentalGenesis testing)
  pure
    NodeConfigurationFromFileV1
      { storageConfiguration = Identity storage
      , consensusConfiguration = Identity consensus
      , protocolConfiguration = Identity protocol
      , networkConfiguration = Identity network
      , localConnectionsConfig = Identity localConnections
      , testingConfiguration = Identity testing
      , mempoolConfiguration = Identity mempool
      , tracingConfiguration = tracing
      , byronGenesisConfig = byronGenesisData
      , shelleyGenesisConfig = shelleyGenesisData
      , alonzoGenesisConfig = alonzoGenesisData
      , conwayGenesisConfig = conwayGenesisData
      , experimentalGenesisConfig = experimentalGenesisData
      }

-- | Convert this library's 'RequiresNetworkMagic' to the Byron ledger's, used
-- when reading the Byron genesis. Absent in the configuration defaults to
-- requiring no magic.
toByronReqNetworkMagic :: Maybe RequiresNetworkMagic -> Byron.RequiresNetworkMagic
toByronReqNetworkMagic = \case
  Just RequiresMagic -> Byron.RequiresMagic
  Just RequiresNoMagic -> Byron.RequiresNoMagic
  Nothing -> Byron.RequiresNoMagic

-- | Read, hash-check and decode an (aeson) era genesis file referenced by the
-- protocol configuration, throwing a 'ConfigurationParsingError' on failure.
readEraGenesisOrThrow ::
  JSONCodec a -> FilePath -> String -> Hashed FilePath -> IO a
readEraGenesisOrThrow genesisCodec root fileKey (Hashed file mHash) = do
  result <- readGenesisFileWith genesisCodec mHash (root </> file)
  case result of
    Left err -> throwIO (genesisReadErrorAt "ProtocolConfig" fileKey err)
    Right genesis -> pure genesis

-- | Read, hash-check and decode the Byron genesis (canonical JSON), throwing a
-- 'ConfigurationParsingError' on failure.
readByronGenesisOrThrow ::
  FilePath -> Byron.RequiresNetworkMagic -> Hashed FilePath -> IO ByronGenesisConfig
readByronGenesisOrThrow root rnm (Hashed file mHash) =
  case mHash of
    Nothing ->
      throwIO $
        ConfigurationParsingError
          (Just (root </> file))
          (Just "ProtocolConfig")
          [Key "ByronGenesisHash"]
          "a Byron genesis file requires a ByronGenesisHash"
    Just expected -> do
      result <- readByronGenesisConfig rnm expected (root </> file)
      case result of
        Left err ->
          throwIO $
            ConfigurationParsingError
              (Just (root </> file))
              (Just "ProtocolConfig")
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
    Left err -> throwIO (genesisReadErrorToParsingError err)
    Right genesis -> pure genesis

-- | Render a 'GenesisReadError' as a 'ConfigurationParsingError' attributed to
-- the @TestingConfig@ section and the offending @DijkstraGenesisFile@.
genesisReadErrorToParsingError :: GenesisReadError -> ConfigurationParsingError
genesisReadErrorToParsingError = genesisReadErrorAt "TestingConfig" "DijkstraGenesisFile"

-- | Render a 'GenesisReadError' as a 'ConfigurationParsingError' attributed to
-- the given section and file key.
genesisReadErrorAt :: String -> String -> GenesisReadError -> ConfigurationParsingError
genesisReadErrorAt section fileKey err =
  ConfigurationParsingError
    (genesisErrorFile err)
    (Just section)
    [Key (K.fromString fileKey)]
    (show err)
