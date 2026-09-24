-- | Configuration options related to networking
module Cardano.Configuration.File.Network
  ( NetworkConfiguration (..)
  , DiffusionMode (..)
  , ResponderCoreAffinityPolicy (..)
  , TxSubmissionLogicVersion (..)
  , AcceptedConnectionsLimit (..)
  , LocalConnectionsConfig (..)
  , GrpcEndpoint (..)
  , GrpcTlsFiles (..)
  , defaultGrpcListenAddress
  , finalizeNetwork
  , finalizeLocalConnections

    -- * Peer selection targets
  , deadlinePeerSelectionTargets
  , syncPeerSelectionTargets

    -- * Role
  , BlockProducerOrRelay (..)
  ) where

import Autodocodec
import Cardano.Configuration.Basic
  ( ErrorMessage
  , diffTimeCodec
  , optionalFieldStrict
  , optionalFieldWithStrict
  , requireField
  )
import Cardano.Configuration.Common
  ( GrpcEndpoint (..)
  , GrpcTlsFiles (..)
  , defaultGrpcListenAddress
  , filePathCodec
  , grpcEndpointObjectCodec
  )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), strictMaybeToMaybe)
import Data.Aeson (FromJSON, ToJSON)
import Data.Functor.Identity (Identity (..))
import Data.Time.Clock (DiffTime)
import Data.Word
import GHC.Generics (Generic)
import Ouroboros.Network.PeerSelection.Governor.Types (PeerSelectionTargets (..))

-- | Whether the node runs as an initiator only, or as both an initiator and a
-- responder. Enumerated so the schema lists the valid values and typos are
-- caught at parse time.
data DiffusionMode
  = InitiatorOnly
  | InitiatorAndResponder
  deriving (Generic, Show, Eq, Enum, Bounded)
  deriving (FromJSON, ToJSON) via (Autodocodec DiffusionMode)

instance HasCodec DiffusionMode where
  codec = shownBoundedEnumCodec

-- | Whether mux responders are pinned to a CPU core. Enumerated (rather than a
-- free 'String') so the schema lists the valid values and typos are caught at
-- parse time. The spellings match the node's @ResponderCoreAffinityPolicy@
-- constructors (@cardano-node@'s @Cardano.Node.Configuration.POM@), which is
-- what consumes this value.
data ResponderCoreAffinityPolicy
  = NoResponderCoreAffinity
  | ResponderCoreAffinity
  deriving (Generic, Show, Eq, Enum, Bounded)
  deriving (FromJSON, ToJSON) via (Autodocodec ResponderCoreAffinityPolicy)

instance HasCodec ResponderCoreAffinityPolicy where
  codec = shownBoundedEnumCodec

-- | Which tx-submission inbound logic the node runs. Enumerated (rather than a
-- free 'String') so the schema lists the valid values and typos are caught at
-- parse time. The spellings match @ouroboros-network@'s
-- @TxSubmissionLogicVersion@ constructors, which is what consumes this value.
data TxSubmissionLogicVersion
  = TxSubmissionLogicV1
  | TxSubmissionLogicV2
  deriving (Generic, Show, Eq, Enum, Bounded)
  deriving (FromJSON, ToJSON) via (Autodocodec TxSubmissionLogicVersion)

instance HasCodec TxSubmissionLogicVersion where
  codec = shownBoundedEnumCodec

-- | Limits on the number of accepted connections.
data AcceptedConnectionsLimit = AcceptedConnectionsLimit
  { hardLimit :: Word32
  , softLimit :: Word32
  , delayOnSoftLimit :: DiffTime
  }
  deriving (Generic, Show)
  deriving (FromJSON, ToJSON) via (Autodocodec AcceptedConnectionsLimit)

instance HasCodec AcceptedConnectionsLimit where
  codec =
    object "AcceptedConnectionsLimit" $
      AcceptedConnectionsLimit
        <$> requiredField "HardLimit" "Hard limit on the number of connections"
          .= hardLimit
        <*> requiredField "SoftLimit" "Soft limit on the number of connections"
          .= softLimit
        <*> requiredFieldWith "Delay" diffTimeCodec "Delay, in seconds, applied once the soft limit is reached"
          .= delayOnSoftLimit

-- | Options related to networking. Fields that have an always-applied default
-- (see @defaults\/Network.json@) carry the @f@ parameter; the deadline peer
-- targets and @PeerSharing@ only have defaults in the opt-in role variants and
-- so stay @Maybe@.
data NetworkConfiguration f = NetworkConfiguration
  { diffusionMode :: f DiffusionMode
  , maxConcurrencyBulkSync :: f Word
  , maxConcurrencyDeadline :: f Word
  , protocolIdleTimeout :: f DiffTime
  , timeWaitTimeout :: f DiffTime
  , egressPollInterval :: f DiffTime
  , chainSyncIdleTimeout :: f DiffTime
  , acceptedConnectionsLimit :: f AcceptedConnectionsLimit
  , deadlineTargetOfRootPeers :: StrictMaybe Int
  , deadlineTargetOfKnownPeers :: StrictMaybe Int
  , deadlineTargetOfEstablishedPeers :: StrictMaybe Int
  , deadlineTargetOfActivePeers :: StrictMaybe Int
  , deadlineTargetOfKnownBigLedgerPeers :: StrictMaybe Int
  , deadlineTargetOfEstablishedBigLedgerPeers :: StrictMaybe Int
  , deadlineTargetOfActiveBigLedgerPeers :: StrictMaybe Int
  , syncTargetOfRootPeers :: f Int
  , syncTargetOfKnownPeers :: f Int
  , syncTargetOfEstablishedPeers :: f Int
  , syncTargetOfActivePeers :: f Int
  , syncTargetOfKnownBigLedgerPeers :: f Int
  , syncTargetOfEstablishedBigLedgerPeers :: f Int
  , syncTargetOfActiveBigLedgerPeers :: f Int
  , minBigLedgerPeersForTrustedState :: f Int
  , peerSharing :: StrictMaybe Bool
  , responderCoreAffinityPolicy :: f ResponderCoreAffinityPolicy
  , experimentalProtocolsEnabled :: f Bool
  , txSubmissionLogicVersion :: f TxSubmissionLogicVersion
  , txSubmissionInitDelay :: f DiffTime
  }
  deriving Generic

deriving instance Show (NetworkConfiguration StrictMaybe)
deriving instance Show (NetworkConfiguration Identity)

deriving via
  (Autodocodec (NetworkConfiguration StrictMaybe))
  instance
    FromJSON (NetworkConfiguration StrictMaybe)

deriving via
  (Autodocodec (NetworkConfiguration StrictMaybe))
  instance
    ToJSON (NetworkConfiguration StrictMaybe)

instance HasCodec (NetworkConfiguration StrictMaybe) where
  codec =
    object "NetworkConfiguration" $
      NetworkConfiguration
        <$> optionalFieldStrict "DiffusionMode" "Initiator-only or initiator-and-responder"
          .= diffusionMode
        <*> optionalFieldStrict "MaxConcurrencyBulkSync" "Bulk-sync block-fetch concurrency"
          .= maxConcurrencyBulkSync
        <*> optionalFieldStrict "MaxConcurrencyDeadline" "Deadline block-fetch concurrency"
          .= maxConcurrencyDeadline
        <*> optionalFieldWithStrict "ProtocolIdleTimeout" diffTimeCodec "Protocol idle timeout, in seconds"
          .= protocolIdleTimeout
        <*> optionalFieldWithStrict "TimeWaitTimeout" diffTimeCodec "TIME-WAIT timeout, in seconds"
          .= timeWaitTimeout
        <*> optionalFieldWithStrict "EgressPollInterval" diffTimeCodec "Egress poll interval, in seconds"
          .= egressPollInterval
        <*> optionalFieldWithStrict "ChainSyncIdleTimeout" diffTimeCodec "ChainSync idle timeout, in seconds"
          .= chainSyncIdleTimeout
        <*> optionalFieldStrict "AcceptedConnectionsLimit" "Limits on accepted connections"
          .= acceptedConnectionsLimit
        <*> optionalFieldStrict "DeadlineTargetNumberOfRootPeers" "Deadline target of root peers"
          .= deadlineTargetOfRootPeers
        <*> optionalFieldStrict "DeadlineTargetNumberOfKnownPeers" "Deadline target of known peers"
          .= deadlineTargetOfKnownPeers
        <*> optionalFieldStrict "DeadlineTargetNumberOfEstablishedPeers" "Deadline target of established peers"
          .= deadlineTargetOfEstablishedPeers
        <*> optionalFieldStrict "DeadlineTargetNumberOfActivePeers" "Deadline target of active peers"
          .= deadlineTargetOfActivePeers
        <*> optionalFieldStrict
          "DeadlineTargetNumberOfKnownBigLedgerPeers"
          "Deadline target of known big ledger peers"
          .= deadlineTargetOfKnownBigLedgerPeers
        <*> optionalFieldStrict
          "DeadlineTargetNumberOfEstablishedBigLedgerPeers"
          "Deadline target of established big ledger peers"
          .= deadlineTargetOfEstablishedBigLedgerPeers
        <*> optionalFieldStrict
          "DeadlineTargetNumberOfActiveBigLedgerPeers"
          "Deadline target of active big ledger peers"
          .= deadlineTargetOfActiveBigLedgerPeers
        <*> optionalFieldStrict "SyncTargetNumberOfRootPeers" "Sync target of root peers"
          .= syncTargetOfRootPeers
        <*> optionalFieldStrict "SyncTargetNumberOfKnownPeers" "Sync target of known peers"
          .= syncTargetOfKnownPeers
        <*> optionalFieldStrict "SyncTargetNumberOfEstablishedPeers" "Sync target of established peers"
          .= syncTargetOfEstablishedPeers
        <*> optionalFieldStrict "SyncTargetNumberOfActivePeers" "Sync target of active peers"
          .= syncTargetOfActivePeers
        <*> optionalFieldStrict "SyncTargetNumberOfKnownBigLedgerPeers" "Sync target of known big ledger peers"
          .= syncTargetOfKnownBigLedgerPeers
        <*> optionalFieldStrict
          "SyncTargetNumberOfEstablishedBigLedgerPeers"
          "Sync target of established big ledger peers"
          .= syncTargetOfEstablishedBigLedgerPeers
        <*> optionalFieldStrict
          "SyncTargetNumberOfActiveBigLedgerPeers"
          "Sync target of active big ledger peers"
          .= syncTargetOfActiveBigLedgerPeers
        <*> optionalFieldStrict "MinBigLedgerPeersForTrustedState" "Minimum big ledger peers for trusted state"
          .= minBigLedgerPeersForTrustedState
        <*> optionalFieldStrict "PeerSharing" "Whether to enable peer sharing" .= peerSharing
        <*> optionalFieldStrict "ResponderCoreAffinityPolicy" "Whether responders are pinned to a core"
          .= responderCoreAffinityPolicy
        <*> optionalFieldStrict "ExperimentalProtocolsEnabled" "Enable experimental network protocols"
          .= experimentalProtocolsEnabled
        <*> optionalFieldStrict "TxSubmissionLogicVersion" "Which tx-submission inbound logic to run"
          .= txSubmissionLogicVersion
        <*> optionalFieldWithStrict
          "TxSubmissionInitDelay"
          diffTimeCodec
          "Tx-submission initial delay, in seconds"
          .= txSubmissionInitDelay

-- | Resolve a partial network configuration, taking the defaulted fields from
-- the (always-applied) base defaults.
finalizeNetwork ::
  NetworkConfiguration StrictMaybe -> Either ErrorMessage (NetworkConfiguration Identity)
finalizeNetwork c = do
  diffusionMode' <- requireField "DiffusionMode" (diffusionMode c)
  maxBulk <- requireField "MaxConcurrencyBulkSync" (maxConcurrencyBulkSync c)
  maxDeadline <- requireField "MaxConcurrencyDeadline" (maxConcurrencyDeadline c)
  protocolIdle <- requireField "ProtocolIdleTimeout" (protocolIdleTimeout c)
  timeWait <- requireField "TimeWaitTimeout" (timeWaitTimeout c)
  egress <- requireField "EgressPollInterval" (egressPollInterval c)
  chainSyncIdle <- requireField "ChainSyncIdleTimeout" (chainSyncIdleTimeout c)
  acceptedLimit <- requireField "AcceptedConnectionsLimit" (acceptedConnectionsLimit c)
  syncRoot <- requireField "SyncTargetNumberOfRootPeers" (syncTargetOfRootPeers c)
  syncKnown <- requireField "SyncTargetNumberOfKnownPeers" (syncTargetOfKnownPeers c)
  syncEstablished <-
    requireField "SyncTargetNumberOfEstablishedPeers" (syncTargetOfEstablishedPeers c)
  syncActive <- requireField "SyncTargetNumberOfActivePeers" (syncTargetOfActivePeers c)
  syncKnownBig <-
    requireField "SyncTargetNumberOfKnownBigLedgerPeers" (syncTargetOfKnownBigLedgerPeers c)
  syncEstBig <-
    requireField "SyncTargetNumberOfEstablishedBigLedgerPeers" (syncTargetOfEstablishedBigLedgerPeers c)
  syncActiveBig <-
    requireField "SyncTargetNumberOfActiveBigLedgerPeers" (syncTargetOfActiveBigLedgerPeers c)
  minBigTrusted <-
    requireField "MinBigLedgerPeersForTrustedState" (minBigLedgerPeersForTrustedState c)
  responderCore <- requireField "ResponderCoreAffinityPolicy" (responderCoreAffinityPolicy c)
  experimental <- requireField "ExperimentalProtocolsEnabled" (experimentalProtocolsEnabled c)
  txLogic <- requireField "TxSubmissionLogicVersion" (txSubmissionLogicVersion c)
  txInitDelay <- requireField "TxSubmissionInitDelay" (txSubmissionInitDelay c)
  pure $
    NetworkConfiguration
      { diffusionMode = diffusionMode'
      , maxConcurrencyBulkSync = maxBulk
      , maxConcurrencyDeadline = maxDeadline
      , protocolIdleTimeout = protocolIdle
      , timeWaitTimeout = timeWait
      , egressPollInterval = egress
      , chainSyncIdleTimeout = chainSyncIdle
      , acceptedConnectionsLimit = acceptedLimit
      , deadlineTargetOfRootPeers = deadlineTargetOfRootPeers c
      , deadlineTargetOfKnownPeers = deadlineTargetOfKnownPeers c
      , deadlineTargetOfEstablishedPeers = deadlineTargetOfEstablishedPeers c
      , deadlineTargetOfActivePeers = deadlineTargetOfActivePeers c
      , deadlineTargetOfKnownBigLedgerPeers = deadlineTargetOfKnownBigLedgerPeers c
      , deadlineTargetOfEstablishedBigLedgerPeers = deadlineTargetOfEstablishedBigLedgerPeers c
      , deadlineTargetOfActiveBigLedgerPeers = deadlineTargetOfActiveBigLedgerPeers c
      , syncTargetOfRootPeers = syncRoot
      , syncTargetOfKnownPeers = syncKnown
      , syncTargetOfEstablishedPeers = syncEstablished
      , syncTargetOfActivePeers = syncActive
      , syncTargetOfKnownBigLedgerPeers = syncKnownBig
      , syncTargetOfEstablishedBigLedgerPeers = syncEstBig
      , syncTargetOfActiveBigLedgerPeers = syncActiveBig
      , minBigLedgerPeersForTrustedState = minBigTrusted
      , peerSharing = peerSharing c
      , responderCoreAffinityPolicy = responderCore
      , experimentalProtocolsEnabled = experimental
      , txSubmissionLogicVersion = txLogic
      , txSubmissionInitDelay = txInitDelay
      }

-- | The deadline peer selection targets as @ouroboros-network@ takes them, or
-- 'Nothing' if the configuration does not set all seven.
--
-- The deadline targets are the one group of network fields with no
-- always-applied default: they come from the role's default configuration, and
-- a configuration may unset one. Seven targets that are only partly given do
-- not describe a target set, so there is nothing to hand over and nothing to
-- check (see 'Cardano.Configuration.defaultConfigChecks').
deadlinePeerSelectionTargets :: NetworkConfiguration f -> Maybe PeerSelectionTargets
deadlinePeerSelectionTargets c =
  PeerSelectionTargets
    <$> strictMaybeToMaybe (deadlineTargetOfRootPeers c)
    <*> strictMaybeToMaybe (deadlineTargetOfKnownPeers c)
    <*> strictMaybeToMaybe (deadlineTargetOfEstablishedPeers c)
    <*> strictMaybeToMaybe (deadlineTargetOfActivePeers c)
    <*> strictMaybeToMaybe (deadlineTargetOfKnownBigLedgerPeers c)
    <*> strictMaybeToMaybe (deadlineTargetOfEstablishedBigLedgerPeers c)
    <*> strictMaybeToMaybe (deadlineTargetOfActiveBigLedgerPeers c)

-- | The sync peer selection targets as @ouroboros-network@ takes them. Every
-- sync target has an always-applied default, so a resolved configuration always
-- has all seven.
syncPeerSelectionTargets :: NetworkConfiguration Identity -> PeerSelectionTargets
syncPeerSelectionTargets c =
  PeerSelectionTargets
    { targetNumberOfRootPeers = runIdentity (syncTargetOfRootPeers c)
    , targetNumberOfKnownPeers = runIdentity (syncTargetOfKnownPeers c)
    , targetNumberOfEstablishedPeers = runIdentity (syncTargetOfEstablishedPeers c)
    , targetNumberOfActivePeers = runIdentity (syncTargetOfActivePeers c)
    , targetNumberOfKnownBigLedgerPeers = runIdentity (syncTargetOfKnownBigLedgerPeers c)
    , targetNumberOfEstablishedBigLedgerPeers = runIdentity (syncTargetOfEstablishedBigLedgerPeers c)
    , targetNumberOfActiveBigLedgerPeers = runIdentity (syncTargetOfActiveBigLedgerPeers c)
    }

-- | Whether the node is a block producer or a relay. Derived from whether the
-- operator supplied block-forging credentials (see
-- @Cardano.Configuration.roleFromCredentials@); it selects which of the two
-- default configurations resolution starts from, and so the deadline
-- peer-selection targets and @PeerSharing@.
data BlockProducerOrRelay
  = IsBlockProducer
  | IsRelay
  deriving (Eq, Show)

-- | Connections for local clients. @EnableGrpc@ has a default. The node socket
-- path and the gRPC endpoint are optional.
--
-- 'grpcEndpoint' stays optional in the resolved form because its default is not
-- a constant: the gRPC server listens on @rpc.sock@ beside the node socket, a
-- path only the consumer can derive.
data LocalConnectionsConfig f = LocalConnectionsConfig
  { socketPath :: StrictMaybe FilePath
  , enableGrpc :: f Bool
  , grpcEndpoint :: StrictMaybe GrpcEndpoint
  }
  deriving Generic

deriving instance Show (LocalConnectionsConfig StrictMaybe)
deriving instance Show (LocalConnectionsConfig Identity)

deriving via
  (Autodocodec (LocalConnectionsConfig StrictMaybe))
  instance
    FromJSON (LocalConnectionsConfig StrictMaybe)

deriving via
  (Autodocodec (LocalConnectionsConfig StrictMaybe))
  instance
    ToJSON (LocalConnectionsConfig StrictMaybe)

instance HasCodec (LocalConnectionsConfig StrictMaybe) where
  codec =
    object "LocalConnectionsConfig" $
      LocalConnectionsConfig
        <$> optionalFieldWithStrict "SocketPath" filePathCodec "Path of the socket for local clients"
          .= socketPath
        <*> optionalFieldStrict "EnableGrpc" "Whether to enable the gRPC server" .= enableGrpc
        <*> grpcEndpointObjectCodec .= grpcEndpoint

-- | Resolve a partial local-connections configuration, taking @EnableGrpc@ from
-- the (always-applied) defaults.
finalizeLocalConnections ::
  LocalConnectionsConfig StrictMaybe -> Either ErrorMessage (LocalConnectionsConfig Identity)
finalizeLocalConnections c = do
  rpc <- requireField "EnableGrpc" (enableGrpc c)
  pure $ LocalConnectionsConfig (socketPath c) rpc (grpcEndpoint c)
