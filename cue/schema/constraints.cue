// Cross-field constraints that the JSON Schema cannot express.
//
// The generated definitions under cue.mod/gen/ (imported from
// ../schemas/*.schema.json) describe the *structure* of each component. They
// do NOT capture the consistency rules cardano-config enforces at load time.
// This file layers those rules on top, so `cue vet` rejects configurations the
// library would reject - with the sole exception of the genesis hash check,
// which requires reading and Blake2b-hashing the referenced files and so stays
// in the library as the final authority.
package schema

// #GrpcConstraints: enabling the gRPC server requires a socket path to bind to,
// either its own GrpcSocketPath or the local-client SocketPath to derive from
// (the library enforces this as a hard error at resolution time). EnableGrpc is
// non-optional (CUE cannot branch on an optional field); its default mirrors the
// library's, so it only materialises when the section is present and then matches
// the default the library would apply anyway.
#GrpcConstraints: {
	EnableGrpc: bool | *false
	if EnableGrpc {
		{SocketPath: string} | {GrpcSocketPath: string}
	}
	...
}

// #MempoolConstraints: the three mempool timeouts are coupled - set all three,
// or none (in which case the library applies 1 / 1.5 / 5 seconds). A partial
// set is rejected. An optional field constrained to bottom (`_|_`) means "must
// be absent"; the first disjunct (the all-absent case) is the default, so a
// MempoolConfig that sets other keys but no timeouts resolves to it; the second
// is the all-present case. A partial set satisfies neither and is rejected.
#MempoolConstraints: {
	*{
		MempoolTimeoutSoft?:     _|_
		MempoolTimeoutHard?:     _|_
		MempoolTimeoutCapacity?: _|_
	} | {
		MempoolTimeoutSoft!:     number
		MempoolTimeoutHard!:     number
		MempoolTimeoutCapacity!: number
	}
	...
}

// #Configuration is the set of component sections, each schema-generated
// definition unified with its constraints. ProtocolConfig is mandatory because
// it carries the genesis files/hashes, which have no defaults. This is the shape
// that goes under the envelope's `Configuration` key.
#Configuration: {
	ProtocolConfig: #ProtocolConfig

	StorageConfig?:          #StorageConfig
	ConsensusConfig?:        #ConsensusConfig
	NetworkConfig?:          #NetworkConfig
	LocalConnectionsConfig?: #LocalConnectionsConfig & #GrpcConstraints
	TestingConfig?:          #TestingConfig
	MempoolConfig?:          #MempoolConfig & #MempoolConstraints

	// Tracing is consumed by trace-dispatcher, not validated here: the value is
	// either a path to a separate file holding the tracing configuration, or that
	// configuration object inline. Its shape is trace-dispatcher's to define, so
	// we accept any object (`{...}`) without constraining its fields - matching the
	// JSON Schema, which types HermodTracing as "a path or a JSON object".
	HermodTracing?: string | {...}
}

// #Node is the authoring view: the recommended Version1 envelope. `cue export`
// of a concrete #Node yields the `{ $schema, Version, MinNodeVersion,
// Configuration }` document the cardano-config library ingests. $schema (the URL
// of the published schema) and Version default, and Configuration is mandatory,
// so all three are emitted automatically; MinNodeVersion has no default and is
// flagged by #warnings when omitted.
#Node: {
	"$schema":       string | *"https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/config.schema.json"
	Version:         int | *1
	MinNodeVersion?: string
	Configuration:   #Configuration
}

// #warnings computes non-fatal advisories for a node - the soft counterpart to
// the hard constraints folded into #Node above. It mirrors cardano-config's
// own ConfigWarning channel: surfaced, never thrown. `just lint` evaluates
// `(schema.#warnings & {in: node}).out` and prints the list without failing.
//
// Each check defaults absent optional fields to their schema default (so e.g.
// an omitted Backend reads as "V2InMemory") and detects field presence with a
// struct comprehension, since CUE cannot branch on an optional field directly.
#warnings: {
	in: #Node

	// Version1 envelope presence. (With #Node, $schema, Version and Configuration
	// are always present - $schema and Version default, Configuration is required
	// - so in practice this flags a missing MinNodeVersion; the others are checked
	// for completeness and to catch a hand-built value that bypasses #Node.)
	let _hasSchema = len([for k, _ in in if k == "$schema" {k}]) > 0
	let _hasVersion = len([for k, _ in in if k == "Version" {k}]) > 0
	let _hasMinNodeVersion = len([for k, _ in in if k == "MinNodeVersion" {k}]) > 0
	let _hasConfiguration = len([for k, _ in in if k == "Configuration" {k}]) > 0

	// Components live under the envelope's Configuration key.
	let _cfg = [for k, v in in if k == "Configuration" {v}, {}][0]
	let _storage = [for k, v in _cfg if k == "StorageConfig" {v}, {}][0]
	let _ldb = [for k, v in _storage if k == "LedgerDB" {v}, {}][0]
	let _backend = [for k, v in _ldb if k == "Backend" {v}, "V2InMemory"][0]
	let _snap = [for k, v in _ldb if k == "Snapshots" {v}, "Mithril"][0]
	// Snapshots may be the string "Mithril" or an options object; narrow to a
	// string (the struct & string mismatch is bottom, which the disjunction
	// drops) so the guard below never compares a struct to a string.
	let _snapStr = *(_snap & string) | "<options>"
	let _hasExport = len([for k, _ in _ldb if k == "LSMExportPath" {k}]) > 0

	out: [
		// Not in the Version1 envelope form.
		if !_hasSchema || !_hasVersion || !_hasMinNodeVersion || !_hasConfiguration {
			"document is not in the Version1 envelope form: expected $schema, Version, MinNodeVersion and Configuration at the top level."
		},
		// V2LSM + Mithril without an export path: allowed, but the LSM backend
		// has nowhere to export snapshots. A warning, not an error.
		if _backend == "V2LSM" if _snapStr == "Mithril" if !_hasExport {
			"Configuration.StorageConfig.LedgerDB: backend V2LSM with Mithril snapshots but no LSMExportPath: the LSM backend has nowhere to export snapshots. Set LSMExportPath, or use the V2InMemory backend."
		},
	]
}
