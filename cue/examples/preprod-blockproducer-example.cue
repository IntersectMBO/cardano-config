// Example: a preprod-testnet block producer using the in-memory ledger backend.
//
// The `preprod` preset supplies the preprod divergences (genesis files/hashes,
// GenesisMode consensus, the pinned snapshot interval). This config uses the
// V2InMemory backend - which keeps the Mithril snapshot policy valid without an
// LSMExportPath - and pins the block-producer role explicitly to show how. (You
// can omit the role: with block-forging credentials supplied on the CLI the
// library selects `blockProducerRole` automatically.) Export with:
//
//   cue export ./examples/preprod-blockproducer-example.cue -e node --out json
package main

import "github.com/intersectmbo/cardano-config/cue/schema"

node: schema.#Node & {
	MinNodeVersion: "10.5.0"

	Configuration: schema.preprod & {
		StorageConfig: LedgerDB: Backend: "V2InMemory"

		NetworkConfig: schema.blockProducerRole & {
			DiffusionMode: "InitiatorAndResponder"
		}
	}
}
