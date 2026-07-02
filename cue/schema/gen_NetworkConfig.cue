// NetworkConfig
//
// NetworkConfiguration
package schema

#NetworkConfig: {
	@jsonschema(schema="http://json-schema.org/draft-07/schema#")
	@jsonschema(id="https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/NetworkConfig.schema.json")

	// $schema
	//
	// URL of the JSON Schema this NetworkConfig file follows (the $schema
	// annotation), for editors and validators.
	$schema?: string

	// AcceptedConnectionsLimit
	//
	// Limits on accepted connections
	// AcceptedConnectionsLimit
	AcceptedConnectionsLimit?: {
		// Delay
		//
		// Delay, in seconds, applied once the soft limit is reached
		Delay!: number

		// HardLimit
		//
		// Hard limit on the number of connections
		HardLimit!: int & <=4294967295 & >=0

		// SoftLimit
		//
		// Soft limit on the number of connections
		SoftLimit!: int & <=4294967295 & >=0
		...
	}

	// ChainSyncIdleTimeout
	//
	// ChainSync idle timeout, in seconds
	ChainSyncIdleTimeout?: number

	// DeadlineTargetNumberOfActiveBigLedgerPeers
	//
	// Deadline target of active big ledger peers
	DeadlineTargetNumberOfActiveBigLedgerPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// DeadlineTargetNumberOfActivePeers
	//
	// Deadline target of active peers
	DeadlineTargetNumberOfActivePeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// DeadlineTargetNumberOfEstablishedBigLedgerPeers
	//
	// Deadline target of established big ledger peers
	DeadlineTargetNumberOfEstablishedBigLedgerPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// DeadlineTargetNumberOfEstablishedPeers
	//
	// Deadline target of established peers
	DeadlineTargetNumberOfEstablishedPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// DeadlineTargetNumberOfKnownBigLedgerPeers
	//
	// Deadline target of known big ledger peers
	DeadlineTargetNumberOfKnownBigLedgerPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// DeadlineTargetNumberOfKnownPeers
	//
	// Deadline target of known peers
	DeadlineTargetNumberOfKnownPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// DeadlineTargetNumberOfRootPeers
	//
	// Deadline target of root peers
	DeadlineTargetNumberOfRootPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// DiffusionMode
	//
	// Initiator-only or initiator-and-responder
	DiffusionMode?: "InitiatorOnly" | "InitiatorAndResponder"

	// EgressPollInterval
	//
	// Egress poll interval, in seconds
	EgressPollInterval?: number

	// ExperimentalProtocolsEnabled
	//
	// Enable experimental network protocols
	ExperimentalProtocolsEnabled?: bool

	// MaxConcurrencyBulkSync
	//
	// Bulk-sync block-fetch concurrency
	MaxConcurrencyBulkSync?: int & <=18446744073709551615.0 & >=0

	// MaxConcurrencyDeadline
	//
	// Deadline block-fetch concurrency
	MaxConcurrencyDeadline?: int & <=18446744073709551615.0 & >=0

	// MinBigLedgerPeersForTrustedState
	//
	// Minimum big ledger peers for trusted state
	MinBigLedgerPeersForTrustedState?: int & <=9223372036854775807 & >=-9223372036854775808

	// PeerSharing
	//
	// Whether to enable peer sharing
	PeerSharing?: bool

	// ProtocolIdleTimeout
	//
	// Protocol idle timeout, in seconds
	ProtocolIdleTimeout?: number

	// ResponderCoreAffinityPolicy
	//
	// Whether responders are pinned to a core
	ResponderCoreAffinityPolicy?: "NoResponderCoreAffinity" | "ResponderCoreAffinity"

	// SyncTargetNumberOfActiveBigLedgerPeers
	//
	// Sync target of active big ledger peers
	SyncTargetNumberOfActiveBigLedgerPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// SyncTargetNumberOfActivePeers
	//
	// Sync target of active peers
	SyncTargetNumberOfActivePeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// SyncTargetNumberOfEstablishedBigLedgerPeers
	//
	// Sync target of established big ledger peers
	SyncTargetNumberOfEstablishedBigLedgerPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// SyncTargetNumberOfEstablishedPeers
	//
	// Sync target of established peers
	SyncTargetNumberOfEstablishedPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// SyncTargetNumberOfKnownBigLedgerPeers
	//
	// Sync target of known big ledger peers
	SyncTargetNumberOfKnownBigLedgerPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// SyncTargetNumberOfKnownPeers
	//
	// Sync target of known peers
	SyncTargetNumberOfKnownPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// SyncTargetNumberOfRootPeers
	//
	// Sync target of root peers
	SyncTargetNumberOfRootPeers?: int & <=9223372036854775807 & >=-9223372036854775808

	// TimeWaitTimeout
	//
	// TIME-WAIT timeout, in seconds
	TimeWaitTimeout?: number

	// TxSubmissionInitDelay
	//
	// Tx-submission initial delay, in seconds
	TxSubmissionInitDelay?: number

	// TxSubmissionLogicVersion
	//
	// Which tx-submission inbound logic to run
	TxSubmissionLogicVersion?: "TxSubmissionLogicV1" | "TxSubmissionLogicV2"
	...
}
