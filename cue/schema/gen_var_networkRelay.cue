package schema

networkRelay: {
	$schema:                                         "https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/NetworkConfig.schema.json"
	DeadlineTargetNumberOfRootPeers:                 60
	DeadlineTargetNumberOfKnownPeers:                150
	DeadlineTargetNumberOfEstablishedPeers:          30
	DeadlineTargetNumberOfActivePeers:               20
	DeadlineTargetNumberOfKnownBigLedgerPeers:       15
	DeadlineTargetNumberOfEstablishedBigLedgerPeers: 10
	DeadlineTargetNumberOfActiveBigLedgerPeers:      5
	PeerSharing:                                     true
}
