// Example: a mainnet relay using the LSM ledger backend with Mithril snapshots.
//
// Authored as a #Node unified with the `mainnet` network preset (which supplies
// the mandatory genesis files/hashes through ProtocolConfig), so `cue vet`
// checks it against the schema and the cross-field constraints. Export with:
//
//   cue export ./examples/mainnet-relay-example.cue -e node --out json
//
// (see the justfile `export` target), producing a single fully-inlined JSON
// document for the cardano-config library to ingest.
package main

import "github.com/intersectmbo/cardano-config/cue/schema"

node: schema.#Node & {
	MinNodeVersion: "10.5.0"

	Configuration: schema.mainnet & {
		StorageConfig: LedgerDB: {
			Backend:       "V2LSM"
			LSMExportPath: "lsm-export" // set, so the LSM backend can export Mithril snapshots
		}

		// A relay accepts inbound connections. The relay peer-target / PeerSharing
		// role overlay is applied automatically by the library from the absence of
		// block-forging credentials, so it is not inlined here.
		NetworkConfig: DiffusionMode: "InitiatorAndResponder"
	}
}
