// TestingConfig
//
// TestingConfiguration
package schema

#TestingConfig: {
	@jsonschema(schema="http://json-schema.org/draft-07/schema#")
	@jsonschema(id="https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/TestingConfig.schema.json")

	// $schema
	//
	// URL of the JSON Schema this TestingConfig file follows (the $schema
	// annotation), for editors and validators.
	$schema?: string

	// DijkstraGenesisFile
	//
	// Path to the genesis file
	DijkstraGenesisFile?: string

	// DijkstraGenesisHash
	//
	// Hash of the genesis file
	// Blake2b_256 hash
	DijkstraGenesisHash?: string

	// ExperimentalHardForksEnabled
	//
	// Enable the experimental eras
	ExperimentalHardForksEnabled?: bool

	// TestAllegraHardForkAtEpoch
	//
	// Force the Allegra hard fork at this epoch
	TestAllegraHardForkAtEpoch?: int & <=18446744073709551615.0 & >=0

	// TestAllegraHardForkAtVersion
	//
	// Force the Allegra hard fork at this protocol version
	TestAllegraHardForkAtVersion?: int & <=18446744073709551615.0 & >=0

	// TestAlonzoHardForkAtEpoch
	//
	// Force the Alonzo hard fork at this epoch
	TestAlonzoHardForkAtEpoch?: int & <=18446744073709551615.0 & >=0

	// TestAlonzoHardForkAtVersion
	//
	// Force the Alonzo hard fork at this protocol version
	TestAlonzoHardForkAtVersion?: int & <=18446744073709551615.0 & >=0

	// TestBabbageHardForkAtEpoch
	//
	// Force the Babbage hard fork at this epoch
	TestBabbageHardForkAtEpoch?: int & <=18446744073709551615.0 & >=0

	// TestBabbageHardForkAtVersion
	//
	// Force the Babbage hard fork at this protocol version
	TestBabbageHardForkAtVersion?: int & <=18446744073709551615.0 & >=0

	// TestConwayHardForkAtEpoch
	//
	// Force the Conway hard fork at this epoch
	TestConwayHardForkAtEpoch?: int & <=18446744073709551615.0 & >=0

	// TestConwayHardForkAtVersion
	//
	// Force the Conway hard fork at this protocol version
	TestConwayHardForkAtVersion?: int & <=18446744073709551615.0 & >=0

	// TestDijkstraHardForkAtEpoch
	//
	// Force the Dijkstra hard fork at this epoch
	TestDijkstraHardForkAtEpoch?: int & <=18446744073709551615.0 & >=0

	// TestDijkstraHardForkAtVersion
	//
	// Force the Dijkstra hard fork at this protocol version
	TestDijkstraHardForkAtVersion?: int & <=18446744073709551615.0 & >=0

	// TestMaryHardForkAtEpoch
	//
	// Force the Mary hard fork at this epoch
	TestMaryHardForkAtEpoch?: int & <=18446744073709551615.0 & >=0

	// TestMaryHardForkAtVersion
	//
	// Force the Mary hard fork at this protocol version
	TestMaryHardForkAtVersion?: int & <=18446744073709551615.0 & >=0

	// TestShelleyHardForkAtEpoch
	//
	// Force the Shelley hard fork at this epoch
	TestShelleyHardForkAtEpoch?: int & <=18446744073709551615.0 & >=0

	// TestShelleyHardForkAtVersion
	//
	// Force the Shelley hard fork at this protocol version
	TestShelleyHardForkAtVersion?: int & <=18446744073709551615.0 & >=0
	...
}
