// ConsensusConfig
//
// ConsensusConfiguration
package schema

#ConsensusConfig: {
	@jsonschema(schema="http://json-schema.org/draft-07/schema#")
	@jsonschema(id="https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/ConsensusConfig.schema.json")

	// $schema
	//
	// URL of the JSON Schema this ConsensusConfig file follows (the $schema
	// annotation), for editors and validators.
	$schema?: string

	// ConsensusMode
	//
	// Which consensus mode to run (PraosMode or GenesisMode)
	ConsensusMode?: "PraosMode" | "GenesisMode"

	// LowLevelGenesisOptions
	//
	// Low-level Genesis tuning (GenesisMode only)
	// GenesisConfigFlags
	LowLevelGenesisOptions?: {
		// BlockFetchGracePeriod
		//
		// Grace period, in seconds, for BlockFetch
		BlockFetchGracePeriod?: number

		// BucketCapacity
		//
		// Token bucket capacity for the LoP
		BucketCapacity?: int

		// BucketRate
		//
		// Token bucket refill rate for the LoP
		BucketRate?: int

		// CSJJumpSize
		//
		// Size, in slots, of ChainSync jumps
		CSJJumpSize?: int & <=18446744073709551615.0 & >=0

		// EnableCSJ
		//
		// Enable ChainSync Jumping
		EnableCSJ?: bool

		// EnableLoEAndGDD
		//
		// Enable the Limit on Eagerness and the Genesis Density Disconnection
		EnableLoEAndGDD?: bool

		// EnableLoP
		//
		// Enable the Limit on Patience
		EnableLoP?: bool

		// GDDRateLimit
		//
		// Rate limit, in seconds, for the GDD
		GDDRateLimit?: number
		...
	}
	...
}
