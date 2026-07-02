// Example: a preview-testnet relay using the LSM ledger backend.
//
// The `preview` preset supplies the preview divergences (genesis files/hashes,
// GenesisMode consensus, the pinned snapshot interval and the Shelley..Alonzo
// hard forks active from epoch 0); this config only adds the LSM backend and the
// relay diffusion mode. Export with:
//
//   cue export ./examples/preview-relay-example.cue -e node --out json
package main

import "github.com/intersectmbo/cardano-config/cue/schema"

node: schema.#Node & {
	MinNodeVersion: "10.5.0"

	Configuration: schema.preview & {
		StorageConfig: LedgerDB: {
			Backend:       "V2LSM"
			LSMExportPath: "lsm-export" // set, so the LSM backend can export Mithril snapshots
		}

		// A relay accepts inbound connections; its peer-target / PeerSharing role
		// overlay is applied automatically by the library (no block-forging
		// credentials), so it is not inlined here.
		NetworkConfig: DiffusionMode: "InitiatorAndResponder"
	}
}
