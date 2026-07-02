-- | Configuration options related to networking
module Cardano.Configuration.File.Network
  ( NetworkConfiguration (..)
  , DiffusionMode (..)
  , ResponderCoreAffinityPolicy (..)
  , TxSubmissionLogicVersion (..)
  , AcceptedConnectionsLimit (..)
  , LocalConnectionsConfig (..)
  , finalizeNetwork
  , finalizeLocalConnections

    -- * Role defaults
  , BlockProducerOrRelay (..)
  , withRoleDefaults
  , networkRoleDefaults
  , blockProducerRoleDefaults
  , relayRoleDefaults
  , emptyNetworkConfiguration
  ) where

import Autodocodec
import Cardano.Configuration.Basic
  ( ErrorMessage
  , diffTimeCodec
  , optionalFieldStrict
  , optionalFieldWithStrict
  , requireField
  )
import Cardano.Configuration.Common (filePathCodec)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Control.Applicative ((<|>))
import Data.Aeson (FromJSON, ToJSON)
import Data.Functor.Identity (Identity (..))
import Data.Time.Clock (DiffTime)
import Data.Word
import GHC.Generics (Generic)

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
        <$> requiredField "hardLimit" "Hard limit on the number of connections"
          .= hardLimit
        <*> requiredField "softLimit" "Soft limit on the number of connections"
          .= softLimit
        <*> requiredFieldWith "delay" diffTimeCodec "Delay, in seconds, applied once the soft limit is reached"
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
        <*> optionalFieldStrict "TargetNumberOfRootPeers" "Deadline target of root peers"
          .= deadlineTargetOfRootPeers
        <*> optionalFieldStrict "TargetNumberOfKnownPeers" "Deadline target of known peers"
          .= deadlineTargetOfKnownPeers
        <*> optionalFieldStrict "TargetNumberOfEstablishedPeers" "Deadline target of established peers"
          .= deadlineTargetOfEstablishedPeers
        <*> optionalFieldStrict "TargetNumberOfActivePeers" "Deadline target of active peers"
          .= deadlineTargetOfActivePeers
        <*> optionalFieldStrict "TargetNumberOfKnownBigLedgerPeers" "Deadline target of known big ledger peers"
          .= deadlineTargetOfKnownBigLedgerPeers
        <*> optionalFieldStrict
          "TargetNumberOfEstablishedBigLedgerPeers"
          "Deadline target of established big ledger peers"
          .= deadlineTargetOfEstablishedBigLedgerPeers
        <*> optionalFieldStrict
          "TargetNumberOfActiveBigLedgerPeers"
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

-- | Whether the node is a block producer or a relay. Derived from whether the
-- operator supplied block-forging credentials (see
-- @Cardano.Configuration.roleFromCredentials@); it selects the deadline
-- peer-selection targets and the @PeerSharing@ default.
data BlockProducerOrRelay
  = IsBlockProducer
  | IsRelay
  deriving (Eq, Show)

-- | Slot the role-derived defaults into the resolution order @base \< role \<
-- user@ for the eight fields the role variants set (the deadline peer targets
-- and @PeerSharing@; they have no CLI flag). For each such field the value the
-- user wrote wins, then the role default, then the base default — so an explicit
-- file value always wins, and the role default beats the base default rather than
-- the other way around.
--
-- This needs the user's layer (no base) /and/ the full base-with-user merge: when
-- the user set a field, @user@ supplies it (and equals @merged@); when the user
-- did not, @merged@ holds the base value, so @role \<|\> merged@ lets the role
-- default override it. Every other field has no role default and is passed
-- through from @merged@ unchanged.
withRoleDefaults ::
  -- | The role defaults (block producer or relay).
  NetworkConfiguration StrictMaybe ->
  -- | The user-supplied layer alone (no base defaults merged in).
  NetworkConfiguration StrictMaybe ->
  -- | The base defaults.
  NetworkConfiguration StrictMaybe ->
  NetworkConfiguration StrictMaybe
withRoleDefaults role user merged =
  merged
    { deadlineTargetOfRootPeers = pick deadlineTargetOfRootPeers
    , deadlineTargetOfKnownPeers = pick deadlineTargetOfKnownPeers
    , deadlineTargetOfEstablishedPeers = pick deadlineTargetOfEstablishedPeers
    , deadlineTargetOfActivePeers = pick deadlineTargetOfActivePeers
    , deadlineTargetOfKnownBigLedgerPeers = pick deadlineTargetOfKnownBigLedgerPeers
    , deadlineTargetOfEstablishedBigLedgerPeers = pick deadlineTargetOfEstablishedBigLedgerPeers
    , deadlineTargetOfActiveBigLedgerPeers = pick deadlineTargetOfActiveBigLedgerPeers
    , peerSharing = pick peerSharing
    }
 where
  -- user value (if any) wins, then the role default, then the base value (held in
  -- the merge when the user left the field unset).
  pick :: (NetworkConfiguration StrictMaybe -> StrictMaybe a) -> StrictMaybe a
  pick f = f user <|> f role <|> f merged

-- | The role defaults for the given role.
networkRoleDefaults :: BlockProducerOrRelay -> NetworkConfiguration StrictMaybe
networkRoleDefaults IsBlockProducer = blockProducerRoleDefaults
networkRoleDefaults IsRelay = relayRoleDefaults

-- | A wholly-unset partial network configuration: every field 'SNothing'. The
-- starting point for the role-default literals below, which set only the eight
-- role fields.
emptyNetworkConfiguration :: NetworkConfiguration StrictMaybe
emptyNetworkConfiguration =
  NetworkConfiguration
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing
    SNothing

-- | The block-producer role defaults. These must equal
-- @variants\/NetworkConfig\/blockproducer.json@ (asserted
-- by a test) and the node's @Ouroboros.defaultDeadlineTargets BlockProducer@ /
-- @PeerSharingDisabled@.
blockProducerRoleDefaults :: NetworkConfiguration StrictMaybe
blockProducerRoleDefaults =
  emptyNetworkConfiguration
    { deadlineTargetOfRootPeers = SJust 100
    , deadlineTargetOfKnownPeers = SJust 100
    , deadlineTargetOfEstablishedPeers = SJust 30
    , deadlineTargetOfActivePeers = SJust 20
    , deadlineTargetOfKnownBigLedgerPeers = SJust 15
    , deadlineTargetOfEstablishedBigLedgerPeers = SJust 10
    , deadlineTargetOfActiveBigLedgerPeers = SJust 5
    , peerSharing = SJust False
    }

-- | The relay role defaults. These must equal
-- @variants\/NetworkConfig\/relay.json@ (asserted by a
-- test) and the node's @Ouroboros.defaultDeadlineTargets Relay@ /
-- @PeerSharingEnabled@.
relayRoleDefaults :: NetworkConfiguration StrictMaybe
relayRoleDefaults =
  emptyNetworkConfiguration
    { deadlineTargetOfRootPeers = SJust 60
    , deadlineTargetOfKnownPeers = SJust 150
    , deadlineTargetOfEstablishedPeers = SJust 30
    , deadlineTargetOfActivePeers = SJust 20
    , deadlineTargetOfKnownBigLedgerPeers = SJust 15
    , deadlineTargetOfEstablishedBigLedgerPeers = SJust 10
    , deadlineTargetOfActiveBigLedgerPeers = SJust 5
    , peerSharing = SJust True
    }

-- | Connections for local clients. @EnableRpc@ has a default; the socket paths
-- are optional.
data LocalConnectionsConfig f = LocalConnectionsConfig
  { socketPath :: StrictMaybe FilePath
  , enableRpc :: f Bool
  , rpcSocketPath :: StrictMaybe FilePath
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
        <*> optionalFieldStrict "EnableRpc" "Whether to enable the gRPC server" .= enableRpc
        <*> optionalFieldWithStrict "RpcSocketPath" filePathCodec "Path of the gRPC server socket"
          .= rpcSocketPath

-- | Resolve a partial local-connections configuration, taking @EnableRpc@ from
-- the (always-applied) defaults.
finalizeLocalConnections ::
  LocalConnectionsConfig StrictMaybe -> Either ErrorMessage (LocalConnectionsConfig Identity)
finalizeLocalConnections c = do
  rpc <- requireField "EnableRpc" (enableRpc c)
  pure $ LocalConnectionsConfig (socketPath c) rpc (rpcSocketPath c)
