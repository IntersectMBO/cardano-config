// LocalConnectionsConfig
//
// LocalConnectionsConfig
package schema

#LocalConnectionsConfig: {
	@jsonschema(schema="http://json-schema.org/draft-07/schema#")
	@jsonschema(id="https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/LocalConnectionsConfig.schema.json")

	// $schema
	//
	// URL of the JSON Schema this LocalConnectionsConfig file follows (the $schema
	// annotation), for editors and validators.
	$schema?: string

	// EnableGrpc
	//
	// Whether to enable the gRPC server
	EnableGrpc?: bool

	// GrpcSocketPath
	//
	// Path of the gRPC server socket
	GrpcSocketPath?: string

	// SocketPath
	//
	// Path of the socket for local clients
	SocketPath?: string
	...
}
