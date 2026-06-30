// StorageConfig
//
// StorageConfiguration
package schema

#StorageConfig: {
	@jsonschema(schema="http://json-schema.org/draft-07/schema#")
	@jsonschema(id="https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/StorageConfig.schema.json")

	// $schema
	//
	// URL of the JSON Schema this StorageConfig file follows (the $schema
	// annotation), for editors and validators.
	$schema?: string

	// DatabasePath
	//
	// Directory (or split directories) where the state is stored
	DatabasePath?: matchN(>=1, [string, {
		// ImmutablePath
		//
		// Directory for the immutable database
		ImmutablePath!: string

		// VolatilePath
		//
		// Directory for the volatile database
		VolatilePath!: string
		...
	}])

	// LedgerDB
	//
	// The LedgerDB configuration
	// LedgerDB
	LedgerDB?: {
		// Backend
		//
		// Which LedgerDB backend to use (V2InMemory or V2LSM)
		Backend?: "V2InMemory" | "V2LSM"

		// LSMDatabasePath
		//
		// Custom path to the LSM database (V2LSM only)
		LSMDatabasePath?: string

		// LSMExportPath
		//
		// Directory into which the LSM backend exports snapshots (V2LSM only)
		LSMExportPath?: string

		// QueryBatchSize
		//
		// Chunk size for large backend reads
		QueryBatchSize?: int & <=18446744073709551615.0 & >=0

		// Snapshots
		//
		// Snapshot policy: "Mithril" or an object of snapshot options
		Snapshots?: matchN(>=1, ["Mithril", {
			// MaxDelay
			//
			// Upper bound (seconds) of the random snapshot delay
			MaxDelay?: int & <=18446744073709551615.0 & >=0

			// MinDelay
			//
			// Lower bound (seconds) of the random snapshot delay
			MinDelay?: int & <=18446744073709551615.0 & >=0

			// NumOfDiskSnapshots
			//
			// How many snapshots to keep on disk
			NumOfDiskSnapshots?: int & <=18446744073709551615.0 & >=0

			// RateLimit
			//
			// Minimum seconds between snapshots
			RateLimit?: int & <=18446744073709551615.0 & >=0

			// SlotOffset
			//
			// Slot at which the snapshot schedule is anchored
			SlotOffset?: int & <=18446744073709551615.0 & >=0

			// SnapshotInterval
			//
			// Slots between snapshots (non-zero)
			SnapshotInterval?: int & <=18446744073709551615.0 & >=0
			...
		}])
		...
	}
	...
}
