// Network and role presets, mirroring variants/<Component>/*.json.
//
// The raw per-component overlays are imported from those JSON files as the
// open `gen_var_*` values (see `just regen`); this file bundles them into the
// per-network and per-role presets an authored config unifies in. They are
// kept open (no `#`) so unifying one into `#Node` only *fills* fields - `#Node`
// stays the single closed gate that rejects unknown keys.
//
// A network diverges across several components, so selecting one means pulling
// in its overlay in each affected section:
//
//   node: #Node & preview & { ...your overrides... }
//
// Genesis files/hashes have no base default, so every network preset supplies
// them through ProtocolConfig.
package schema

// mainnet: only ProtocolConfig diverges from the base defaults (PraosMode,
// Mithril snapshots and no hard-fork-at-epoch overrides are already the base).
mainnet: {
	ProtocolConfig: protocolMainnet
}

// preview: ProtocolConfig + GenesisMode consensus + pinned snapshot interval +
// the Shelley..Alonzo hard forks active from epoch 0.
preview: {
	ProtocolConfig:  protocolPreview
	ConsensusConfig: consensusPreview
	StorageConfig:   storagePreview
	TestingConfig:   testingPreview
}

// preprod: ProtocolConfig + GenesisMode consensus + pinned snapshot interval
// (no Testing overlay - preprod launched without pre-activated eras).
preprod: {
	ProtocolConfig:  protocolPreprod
	ConsensusConfig: consensusPreprod
	StorageConfig:   storagePreprod
}

// Role overlays for NetworkConfig (deadline peer targets + PeerSharing).
//
// NOTE: cardano-config applies one of these AUTOMATICALLY at resolution time,
// chosen by whether block-forging credentials were supplied, as a layer below
// the configuration file. Inlining one here is therefore optional and, because
// the file layer wins, OVERRIDES that automatic selection - only do so to pin a
// role explicitly. Usage:
//
//   node: #Node & mainnet & { NetworkConfig: relayRole }
relayRole:         networkRelay
blockProducerRole: networkBlockproducer
