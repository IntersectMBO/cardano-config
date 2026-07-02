// ProtocolConfig
//
// ProtocolConfiguration
package schema

#ProtocolConfig: {
	@jsonschema(schema="http://json-schema.org/draft-07/schema#")
	@jsonschema(id="https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/ProtocolConfig.schema.json")

	// $schema
	//
	// URL of the JSON Schema this ProtocolConfig file follows (the $schema
	// annotation), for editors and validators.
	$schema?: string

	// AlonzoGenesisFile
	//
	// Path to the genesis file
	AlonzoGenesisFile!: string

	// AlonzoGenesisHash
	//
	// Hash of the genesis file
	// Blake2b_256 hash
	AlonzoGenesisHash!: string

	// ByronGenesisFile
	//
	// Path to the genesis file
	ByronGenesisFile!: string

	// ByronGenesisHash
	//
	// Hash of the genesis file
	// Blake2b_256 hash
	ByronGenesisHash!: string

	// CheckpointsFile
	//
	// Path to the file
	CheckpointsFile?: string

	// CheckpointsFileHash
	//
	// Hash of the file
	// Blake2b_256 hash
	CheckpointsFileHash?: string

	// ConwayGenesisFile
	//
	// Path to the genesis file
	ConwayGenesisFile!: string

	// ConwayGenesisHash
	//
	// Hash of the genesis file
	// Blake2b_256 hash
	ConwayGenesisHash!: string

	// RequiresNetworkMagic
	//
	// Whether network magic is required
	RequiresNetworkMagic?: "RequiresNoMagic" | "RequiresMagic"

	// ShelleyGenesisFile
	//
	// Path to the genesis file
	ShelleyGenesisFile!: string

	// ShelleyGenesisHash
	//
	// Hash of the genesis file
	// Blake2b_256 hash
	ShelleyGenesisHash!: string

	// StartAsNonProducingNode
	//
	// Start the node without block production even when block-forging credentials
	// are supplied. false (the default) behaves normally — producing blocks if
	// credentials were supplied, otherwise just running as a relay; true
	// suppresses block production even with credentials present.
	StartAsNonProducingNode?: bool
	...
}
