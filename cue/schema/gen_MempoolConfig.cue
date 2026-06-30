// MempoolConfig
//
// MempoolConfiguration
package schema

#MempoolConfig: {
	@jsonschema(schema="http://json-schema.org/draft-07/schema#")
	@jsonschema(id="https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/MempoolConfig.schema.json")

	// $schema
	//
	// URL of the JSON Schema this MempoolConfig file follows (the $schema
	// annotation), for editors and validators.
	$schema?: string

	// MempoolCapacityBytesOverride
	//
	// Override for the maximum mempool size in bytes, or the string "NoOverride"
	MempoolCapacityBytesOverride?: matchN(>=1, [int & <=18446744073709551615.0 & >=0, "NoOverride"])

	// MempoolTimeoutCapacity
	//
	// Capacity mempool timeout, in seconds
	MempoolTimeoutCapacity?: number

	// MempoolTimeoutHard
	//
	// Hard mempool timeout, in seconds
	MempoolTimeoutHard?: number

	// MempoolTimeoutSoft
	//
	// Soft mempool timeout, in seconds
	MempoolTimeoutSoft?: number
	...
}
