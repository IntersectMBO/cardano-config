-- | Parse the configuration for a @cardano-node@, combining both the
-- t'Cardano.Configuration.CliArgs' and the
-- t'Cardano.Configuration.NodeConfigurationFromFile'
--
-- The configuration file can be either in JSON or in YAML format.
module Cardano.Configuration
  ( -- * Configuration
    NodeConfiguration (..)
  , resolveConfiguration
  , resolveConfigurationWith

    -- ** Consistency checks
  , ConfigCheck (..)
  , CheckSeverity (..)
  , defaultConfigChecks
  , ConfigResolutionError (..)

    -- ** Storage
  , File.StorageConfiguration (..)
  , File.LedgerDbConfiguration (..)
  , File.SnapshotPolicy (..)
  , File.SnapshotOptions (..)
  , File.mithrilSnapshotOptions
  , File.resolveSnapshotPolicy
  , File.LedgerDbBackendSelector (..)
  , File.NodeDatabasePaths (..)

    -- ** Consensus
  , File.ConsensusConfiguration (..)
  , File.ConsensusMode (..)
  , File.GenesisConfigFlags (..)

    -- ** Protocol
  , File.ProtocolConfiguration (..)
  , File.ByronGenesisConfiguration (..)
  , File.RequiresNetworkMagic (..)
  , File.Hashed (..)
  , CLI.Credentials (..)
  , CLI.KESSource (..)

    -- ** Network
  , File.NetworkConfiguration (..)
  , File.DiffusionMode (..)
  , File.AcceptedConnectionsLimit (..)
  , File.LocalConnectionsConfig (..)

    -- ** Testing
  , File.TestingConfiguration (..)
  , CLI.TracerConnection (..)

    -- ** Mempool
  , File.MempoolConfiguration (..)

    -- ** Genesis

    -- | The era genesis types of the resolved 'NodeConfiguration' fields. The
    --     later eras come from @cardano-ledger@ (@ShelleyGenesis@, @AlonzoGenesis@,
    --     @ConwayGenesis@, @DijkstraGenesis@); only Byron's is defined here.
  , ByronGenesisConfig

    -- ** Operational
  , CLI.ShutdownOn (..)

    -- * CLI
  , CLI.CliArgs
  , CLI.parseCliArgs

    -- ** Reusable option parsers
  , CLI.parseConfigFile
  , CLI.parseTopologyFile
  , CLI.parseSocketPath
  , CLI.parseValidateDB
  , CLI.parseEnableRpc
  , CLI.parseRpcSocketPath
  , CLI.parseCredentials
  , CLI.parseKESSource
  , CLI.parseHostIPv4Addr
  , CLI.parseHostIPv6Addr
  , CLI.parsePort
  , CLI.parseTracerSocketMode
  , CLI.parseShutdownIPC
  , CLI.parseShutdownOn
  , CLI.parseNodeAddress
  , CLI.parseHostPort

    -- * Configuration file
  , File.NodeConfigurationFromFile
  , File.TracingConfiguration (..)
  , File.parseConfigurationFiles
  , File.ConfigWarning (..)
  , File.renderConfigWarning
  , File.ConfigurationParsingError (..)
  ) where

import qualified Cardano.Configuration.CliArgs as CLI
import qualified Cardano.Configuration.Common as File
import qualified Cardano.Configuration.File as File
import Cardano.Configuration.File.Consensus
import qualified Cardano.Configuration.File.Consensus as File
import qualified Cardano.Configuration.File.Protocol as File
import qualified Cardano.Configuration.File.Storage as File
import Cardano.Configuration.Genesis.Byron (ByronGenesisConfig)
import Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis)
import Cardano.Ledger.Conway.Genesis (ConwayGenesis)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis)
import Cardano.Ledger.Shelley.Genesis (ShelleyGenesis)
import Control.Applicative ((<|>))
import Control.Exception (Exception)
import Data.Functor.Identity
import Data.IP
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe
import Network.Socket
import System.Posix.Types

-- | The complete configuration for a cardano-node, combining the configuration
-- file and the cli arguments
data NodeConfiguration = NodeConfiguration
  { storageConfiguration :: File.StorageConfiguration Identity
  , consensusConfiguration :: File.ConsensusConfiguration Identity
  , protocolConfiguration :: File.ProtocolConfiguration Identity
  , networkConfiguration :: File.NetworkConfiguration Identity
  , localConnectionsConfig :: File.LocalConnectionsConfig Identity
  , testingConfiguration :: File.TestingConfiguration Identity
  , mempoolConfiguration :: File.MempoolConfiguration Identity
  , byronGenesisConfig :: ByronGenesisConfig
  -- ^ The parsed Byron genesis.
  , shelleyGenesisConfig :: ShelleyGenesis
  -- ^ The parsed Shelley genesis.
  , alonzoGenesisConfig :: AlonzoGenesis
  -- ^ The parsed Alonzo genesis.
  , conwayGenesisConfig :: ConwayGenesis
  -- ^ The parsed Conway genesis.
  , experimentalGenesisConfig :: Maybe DijkstraGenesis
  -- ^ The parsed experimental (Dijkstra) genesis, decoded from the
  --     @DijkstraGenesisFile@ referenced by the testing configuration, if any.
  , configFilePath :: FilePath
  , topologyFile :: FilePath
  , validateDatabase :: Bool
  , credentials :: CLI.Credentials
  , hostAddr :: Maybe IPv4
  , hostIPv6Addr :: Maybe IPv6
  , port :: Maybe PortNumber
  , tracerSocket :: Maybe CLI.TracerConnection
  , shutdownIPC :: Maybe Fd
  , shutdownOnTarget :: Maybe CLI.ShutdownOn
  }
  deriving Show

-- | How a failed 'ConfigCheck' is treated: 'CheckError' aborts resolution with
-- a 'ConfigResolutionError'; 'CheckWarning' lets resolution succeed but surfaces
-- a 'File.ConsistencyWarning' alongside the resolved configuration.
data CheckSeverity
  = CheckError
  | CheckWarning
  deriving (Eq, Show)

-- | A single consistency check over a resolved 'NodeConfiguration': an
-- invariant that must hold, together with a description used when it fails and
-- a severity deciding whether a failure is fatal or merely a warning.
-- Consumers can define their own and pass them to 'resolveConfigurationWith'.
data ConfigCheck = ConfigCheck
  { checkSeverity :: CheckSeverity
  -- ^ Whether a failure aborts resolution ('CheckError') or is surfaced as a
  --     non-fatal warning ('CheckWarning').
  , checkDescription :: String
  -- ^ A description of the invariant, phrased as what must hold (used in the
  --     error or warning message when it does not).
  , checkHolds :: NodeConfiguration -> Bool
  -- ^ The invariant. 'True' means the configuration satisfies it.
  }

-- | An error detected while resolving the configuration: one or more
-- consistency checks failed on a configuration whose individual values were
-- each well-formed. Carries the descriptions of the violated checks.
newtype ConfigResolutionError = ConfigResolutionError
  { violatedChecks :: NonEmpty String
  }
  deriving (Eq, Show)

instance Exception ConfigResolutionError

-- | The built-in consistency checks applied by 'resolveConfiguration'. Exported
-- so consumers can extend them, e.g.
-- @'resolveConfigurationWith' (defaultConfigChecks <> myChecks)@.
defaultConfigChecks :: [ConfigCheck]
defaultConfigChecks =
  [ ConfigCheck
      CheckError
      "Enabling the gRPC endpoint requires a gRPC socket path, or a node socket path to derive one from"
      ( \nc ->
          let lcc = localConnectionsConfig nc
           in not (runIdentity (File.enableRpc lcc))
                || isJust (File.rpcSocketPath lcc)
                || isJust (File.socketPath lcc)
      )
  , ConfigCheck
      CheckWarning
      ( "the Mithril snapshot policy under the V2LSM backend has no LSMExportPath, so the LSM backend "
          <> "cannot export snapshots; set an LSMExportPath, or use the V2InMemory backend"
      )
      ( \nc ->
          let ldb = runIdentity (File.ledgerDbConfiguration (storageConfiguration nc))
           in case File.snapshots ldb of
                Just File.MithrilSnapshotPolicy ->
                  case File.backendSelector ldb of
                    Nothing -> True -- defaults to V2InMemory, which satisfies Mithril
                    Just File.V2InMemory -> True
                    Just (File.V2LSM _ exportPath) -> isJust exportPath
                _ -> True
      )
  ]

-- | Run a set of consistency checks over a resolved configuration. Any failed
-- 'CheckError' aborts with a 'ConfigResolutionError' listing their descriptions;
-- otherwise resolution succeeds and every failed 'CheckWarning' is returned as a
-- 'File.ConsistencyWarning' for the caller to surface.
runConfigChecks ::
  [ConfigCheck] ->
  NodeConfiguration ->
  Either ConfigResolutionError (NodeConfiguration, [File.ConfigWarning])
runConfigChecks checks nc =
  case [checkDescription c | c <- checks, checkSeverity c == CheckError, not (checkHolds c nc)] of
    (violation : violations) -> Left (ConfigResolutionError (violation :| violations))
    [] ->
      Right
        ( nc
        , [ File.ConsistencyWarning (checkDescription c)
          | c <- checks
          , checkSeverity c == CheckWarning
          , not (checkHolds c nc)
          ]
        )

-- | Combine the cli arguments and configuration file values into a full
-- configuration, then check it with 'defaultConfigChecks'. CLI values take
-- precedence over file values.
resolveConfiguration ::
  CLI.CliArgs ->
  File.NodeConfigurationFromFile ->
  Either ConfigResolutionError (NodeConfiguration, [File.ConfigWarning])
resolveConfiguration = resolveConfigurationWith defaultConfigChecks

-- | As 'resolveConfiguration', but with an explicit set of consistency checks,
-- so consumers can add their own (typically @'defaultConfigChecks' <> myChecks@).
-- On success returns the resolved configuration together with any non-fatal
-- warnings raised by 'CheckWarning'-severity checks.
resolveConfigurationWith ::
  [ConfigCheck] ->
  CLI.CliArgs ->
  File.NodeConfigurationFromFile ->
  Either ConfigResolutionError (NodeConfiguration, [File.ConfigWarning])
resolveConfigurationWith checks cli file = do
  -- Components with an always-applied defaults layer are finalized to their
  -- complete 'Identity' form; a missing default surfaces as a resolution error.
  --
  -- The networking role defaults (deadline peer targets and PeerSharing) are
  -- derived from whether the operator supplied block-forging credentials and
  -- slotted into the resolution order base < role < user, so an explicit file
  -- value wins and the role default beats the base default (see
  -- 'File.withRoleDefaults').
  let roleDefaults = File.networkRoleDefaults (roleFromCredentials (CLI.credentials cli))
      netMerged = runIdentity (File.networkConfiguration file)
      netUser = runIdentity (File.networkUserLayer file)
  network <- finalize $ File.finalizeNetwork (File.withRoleDefaults roleDefaults netUser netMerged)
  testing <- finalize $ File.finalizeTesting (runIdentity (File.testingConfiguration file))
  mempool <- finalize $ File.finalizeMempool (runIdentity (File.mempoolConfiguration file))
  -- Local connections additionally take CLI overrides before being finalized.
  let lcc = runIdentity $ File.localConnectionsConfig file
      lccWithCli =
        lcc
          { File.socketPath = CLI.socketPath cli <|> File.socketPath lcc
          , File.enableRpc = CLI.enableRpcCLI cli <|> File.enableRpc lcc
          , File.rpcSocketPath = CLI.rpcSocketPathCLI cli <|> File.rpcSocketPath lcc
          }
  localConnections <- finalize $ File.finalizeLocalConnections lccWithCli
  -- Storage, consensus and the non-producing flag take their value from the CLI
  -- or the file (whose always-applied base-default layer supplies the default).
  -- A missing value is a resolution error, not a hard-coded fallback, so the
  -- defaults live solely in the defaults/ files.
  let sc = runIdentity $ File.storageConfiguration file
      pc = runIdentity $ File.protocolConfiguration file
  dbPath <- finalize $ require "DatabasePath" (CLI.databasePathCLI cli <|> File.databasePath sc)
  consensusMode <-
    finalize $
      require "ConsensusMode" (getConsensusConfiguration (runIdentity (File.consensusConfiguration file)))
  startNonProducing <-
    finalize $
      require
        "StartAsNonProducingNode"
        (CLI.startAsNonProducingNode cli <|> File.startAsNonProducingNode pc)
  -- Run the consistency checks while the snapshot policy is still its requested
  -- form (the Mithril/LSMExportPath check needs to see "Mithril"), then resolve
  -- it to concrete options so the result carries no bare "Mithril" policy.
  (resolved, warnings) <-
    runConfigChecks checks $
      NodeConfiguration
        { storageConfiguration = File.adjustDbPath sc dbPath
        , consensusConfiguration = ConsensusConfiguration (Identity consensusMode)
        , protocolConfiguration = pc{File.startAsNonProducingNode = Identity startNonProducing}
        , networkConfiguration = network
        , localConnectionsConfig = localConnections
        , testingConfiguration = testing
        , mempoolConfiguration = mempool
        , byronGenesisConfig = File.byronGenesisConfig file
        , shelleyGenesisConfig = File.shelleyGenesisConfig file
        , alonzoGenesisConfig = File.alonzoGenesisConfig file
        , conwayGenesisConfig = File.conwayGenesisConfig file
        , experimentalGenesisConfig = File.experimentalGenesisConfig file
        , configFilePath = CLI.configFilePath cli
        , topologyFile = CLI.topologyFile cli
        , validateDatabase = CLI.validateDatabase cli
        , credentials = CLI.credentials cli
        , hostAddr = CLI.hostAddr cli
        , hostIPv6Addr = CLI.hostIPv6Addr cli
        , port = CLI.port cli
        , tracerSocket = CLI.tracerSocket cli
        , shutdownIPC = CLI.shutdownIPC cli
        , shutdownOnTarget = CLI.shutdownOnTarget cli
        }
  pure
    ( resolved{storageConfiguration = File.resolveSnapshotOptions (storageConfiguration resolved)}
    , warnings
    )
 where
  finalize = either (\m -> Left (ConfigResolutionError (m :| []))) Right
  require name = maybe (Left (name <> " has no value and no base default")) Right

-- | Derive the node's role from its credentials: it is a block producer iff
-- /any/ block-forging credential was supplied, otherwise a relay. This matches
-- @cardano-node@'s @hasProtocolFile@ semantics and selects the network role
-- defaults (see 'File.withRoleDefaults').
roleFromCredentials :: CLI.Credentials -> File.BlockProducerOrRelay
roleFromCredentials c
  | any
      isJust
      [ () <$ CLI.byronDelegationCertificate c
      , () <$ CLI.byronSigningKey c
      , () <$ CLI.shelleyKES c
      , () <$ CLI.shelleyVRFKey c
      , () <$ CLI.shelleyOperationalCertificate c
      , () <$ CLI.bulkCredentialsFile c
      ] =
      File.IsBlockProducer
  | otherwise = File.IsRelay
