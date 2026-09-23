# Revision history for cardano-config

## Unreleased

Schema format version 2, and so package version `2.0.0.0`: the configuration
format gains keys (below), and the `v1` tag, cut alongside
`cardano-config-1.1.0.0`, is immutable. The schemas that describe the format can
no longer be published under it. `cardano-config-2.x.x.x` parses every format
version up to and including 2 and writes 2. A version-1 document still parses,
because `migrate` upgrades it to version 2 before the parser sees it.

The schemas now state the cross-field rules the parser enforces (below), so a
validator rejects documents `v1` accepted. Every one of those was already
rejected at parse time. The new keys themselves are additive: the sections do
not set `additionalProperties: false`, so a configuration carrying them already
validated against `v1`.

One working configuration does stop working: one whose sections name sub-files.
The split-file form is gone, so those sections hold their objects now (below).

### Breaking changes

* A configuration is held in one file. A section key (`StorageConfig`,
  `ProtocolConfig`, …) took either an inline object or a path to a sub-file the
  parser read and layered in; it now takes the inline object alone. A section
  holding anything else is rejected, naming the section. The genesis files and
  the `HermodTracing` file are unaffected: those are still paths.

  To port a split configuration, copy each sub-file's contents in under its
  section key. `migrate` cannot do it for you — reading those files is exactly
  what it does not do — so it refuses such a document instead of writing one
  the parser will not read.

  `migrate` therefore returns `Either MigrationError (Value, [ConfigWarning])`
  rather than the pair, with `renderMigrationError` for the message. The files
  under `variants/` stay in the repository as templates to copy from, but a
  configuration can no longer point at one.

  In the library, `Cardano.Configuration.File.Merge` loses `loadSectionSource`
  and the containment check that kept a sub-file inside the configuration
  directory, and `parseSection` and `sectionUserLayer` no longer take a root
  directory.

* An `UnrecognisedKeys` warning now reports only a name no parser claims (a
  typo, or a key of an unknown component). It used to also cover a component
  property left flat under `Configuration` when that component's section was a
  sub-file path; with no sub-file paths left, `migrate` groups such a property
  under the section that owns it in every case.

* The whole-configuration schema describes each section as the component's own
  schema, instead of "a file path or that schema". The flat legacy form is no
  longer called "one-file", since one file is what every configuration is now:
  `schema --legacy-one-file` becomes `schema --legacy-flat`, writing
  `schemas/config.legacy-flat.schema.json`. In the library,
  `splitConfigSchema`/`splitConfigSchemaWithDefaults` become
  `configSchema`/`configSchemaWithDefaults`, and
  `legacyOneFileConfigSchema`/`legacyOneFileConfigSchemaWithDefaults` become
  `legacyFlatConfigSchema`/`legacyFlatConfigSchemaWithDefaults`.
  `Cardano.Configuration.Commands.ConfigForm` renames its constructors to
  `CurrentForm` and `LegacyFlatForm`.

* The configuration schema describes the envelope and only the envelope. It
  used to put the section keys at the *top* level, beside `Version`, and
  declare `Configuration` as a bare `{"type": "object"}` — so it validated a
  shape nothing recommends and let anything at all through inside the envelope.
  A document with a partial mempool timeout set validated against it. The
  sections now sit under `Configuration`, where the parser reads them, and
  `Version` and `Configuration` are required, so a legacy document fails
  validation as the README has always said it should.

  This is a change to what validates, and it rejects documents the `v2`
  schema accepted, but every one of those was already rejected at parse time.

* `NodeConfigurationFromFile` is a plain record. It was
  `NodeConfigurationFromFileF Identity`, where the `f` parameter staged a
  component that might still be a sub-file reference against one already read;
  with no sub-files there is one stage. Each field now holds its component
  directly, so a consumer drops the `runIdentity` around
  `storageConfiguration`, `protocolConfiguration` and the rest. The type
  synonym and `NodeConfigurationFromFileF` are gone, and the constructor is
  `NodeConfigurationFromFile`, not `NodeConfigurationFromFileV1`.

* `Cardano.Configuration.File.Merge.runCodec` loses its `Maybe FilePath`
  argument and `decodeValueFile` loses its `Maybe String` section argument.
  Both only ever named a sub-file, so every caller passed `Nothing`.

* `migrate` writes the current format version instead of carrying an older one
  through, so a legacy or a version-1 document comes out at version 2 with the
  matching `$schema`. A document already at the current version keeps a
  `$schema` it pins. A document declaring a newer version is refused, both by
  `migrate` and when read, because migration never goes backwards.

  `parseConfigurationFiles` migrates before it parses, so this removes the
  per-version dispatch: every document reaches one body parser, at the current
  version. A new format version now costs one migration step, not one parse
  path.

* `ConfigWarning` gains `OutdatedFormatVersion declared current`, raised when a
  document is at an older format version. It replaces `MigratedToCurrentFormat`
  in that case, which now reports only a document already at the current
  version that migration still had to change. Code matching exhaustively on
  `ConfigWarning` has to account for it.

* The `migrate` subcommand prints a line to stderr telling you to check the
  result with `resolve`. `migrate` itself still does not parse, resolve or
  validate, so it stays a purely structural rewrite.

* The gRPC server can now listen over HTTP/2 on a TCP port, with or without
  TLS, rather than only on a unix socket. This follows `cardano-node`'s
  `RpcEndpoint`. `LocalConnectionsConfig` replaces its
  `grpcSocketPath :: StrictMaybe FilePath` field with
  `grpcEndpoint :: StrictMaybe GrpcEndpoint`, the choice among the three
  listeners:

  ```haskell
  data GrpcEndpoint
    = GrpcEndpointUnixSocket FilePath
    | GrpcEndpointHttp IP PortNumber
    | GrpcEndpointHttps IP PortNumber GrpcTlsFiles
  ```

  It is one field rather than a group of independent ones, because the server
  has exactly one listener. The combinations that describe none are now
  unrepresentable in a resolved configuration. It stays a `StrictMaybe` once
  resolved: unset, the consumer derives `rpc.sock` beside the node socket.

  In the configuration file the endpoint is written flat, under
  `LocalConnectionsConfig`: the existing `GrpcSocketPath`, or the new
  `GrpcListenPort`, with an optional `GrpcListenAddress` defaulting to
  `127.0.0.1`. For TLS, add `GrpcTlsCertificateFile` and
  `GrpcTlsPrivateKeyFile`, with optional `GrpcTlsChainCertificateFiles`. These
  keys are folded into the endpoint as the section is parsed. The combinations
  that describe no single listener are rejected there, naming the keys at
  fault.

* `CliArgs` likewise replaces `grpcSocketPathCLI :: StrictMaybe FilePath` with
  `grpcEndpointCLI :: StrictMaybe GrpcEndpoint`. It is parsed from the existing
  `--grpc-socket-path` and the new `--grpc-listen-address`,
  `--grpc-listen-port`, `--grpc-tls-certificate`, `--grpc-tls-private-key` and
  (repeatable) `--grpc-tls-chain-certificate`, whose names and help text match
  `cardano-node`'s. The unix-socket flag and the TCP ones are alternatives, so
  giving both fails the parse. A command-line endpoint replaces the file's
  endpoint whole rather than merging into it.

  The individual parsers are exported as usual (`parseGrpcEndpoint`,
  `parseGrpcSocketPath`, `parseGrpcListenAddress`, `parseGrpcListenPort`,
  `parseGrpcTlsFiles`), as are `GrpcEndpoint`, `GrpcTlsFiles` and
  `defaultGrpcListenAddress`.

* The consistency check on enabling gRPC now accepts an endpoint of any kind: a
  gRPC socket path, a listen port, or a node socket path. A configuration that
  enables gRPC on a listen port and names no node socket used to be rejected.
  It now resolves, and the check's `checkDescription` text changed with it.

* `experimentalGenesisConfig` (on both `NodeConfigurationFromFile` and
  `NodeConfiguration`) is now gated on the `ExperimentalHardForksEnabled`
  testing flag: it is `SJust` only when the flag is on *and* a
  `DijkstraGenesisFile` is named. With the flag off it is `SNothing` even if the
  configuration names a file, and the file is not opened at all — not read, not
  hash-checked.

  This follows `cardano-node`, which gates its whole Dijkstra
  protocol-configuration block on the same flag and, with the flag off,
  substitutes an empty Dijkstra genesis without ever looking at a file. Reading
  it here would reject configurations the node accepts, and the field's old
  meaning — "a file was named" — was not the question a consumer has to answer.
  Every consumer had to re-derive "is there an experimental genesis in play?"
  from the flag itself, and they disagreed on the answer; now the field states
  it.

  The price of not reading the file is that a stale `DijkstraGenesisHash`, or a
  file that has since been moved away, goes unreported while the flag is off.
  The file being ignored at all is reported, though, by the new warning below.

* `ConfigWarning` gains an `ExperimentalGenesisIgnored` constructor, raised by
  `parseConfigurationFiles` when a `DijkstraGenesisFile` is named while
  `ExperimentalHardForksEnabled` is off. Code matching exhaustively on
  `ConfigWarning` has to account for it.

* The converse is now an error: `finalizeTesting` — and so `resolveConfiguration`
  — rejects `ExperimentalHardForksEnabled: true` without a `DijkstraGenesisFile`.
  `cardano-node` makes that key mandatory inside the very block it parses only
  when the flag is on, and enabling an era with no genesis to run it from is not
  a configuration anyone meant to write. A configuration that set the flag and
  named no genesis used to resolve; it now fails with a message naming both keys.

  Together with the gating above this makes the pair exact rather than
  one-sided: on a resolved `NodeConfiguration`, `experimentalGenesisConfig` is
  `SJust` if and only if `experimentalHardForksEnabled` is set. Both of the
  combinations where the two disagree are now unreachable, so a consumer that
  used to handle four has two.

### Added

* `migrate` rewrites the remaining `Rpc*` key names to their `Grpc*` form:
  `RpcListenAddress`, `RpcListenPort`, `RpcTlsCertificateFile`,
  `RpcTlsPrivateKeyFile` and `RpcTlsChainCertificateFiles`, alongside the
  `EnableRpc`/`RpcSocketPath` pair it already handled.

  The schemas gain the new keys, and `migrate` now stamps `Version: 2` on the
  documents it reshapes. An existing `Version`, like an existing `$schema`, is
  carried through untouched, so a document pinned to an earlier version stays
  pinned.

### Changed

* The schemas state the cross-field rules the parser enforces. A codec cannot
  express them, because it derives the schema one key at a time:

  - the gRPC endpoint is one listener, so `GrpcSocketPath` excludes the TCP
    keys, `GrpcListenAddress` and the `GrpcTls*` keys require `GrpcListenPort`,
    and the certificate and private key require each other (`dependencies`)
  - `MempoolTimeoutSoft`, `MempoolTimeoutHard` and `MempoolTimeoutCapacity` are
    all set or all unset (`dependencies`)
  - `ExperimentalHardForksEnabled` requires a `DijkstraGenesisFile` and
    `DijkstraGenesisHash` (`if`/`then`), and those two require each other
  - `SnapshotInterval` is `minimum: 1`, not the 0 its `Word64` would allow

  Only rules whose inputs all come from the configuration file are stated.
  "Enabling gRPC needs somewhere to listen" is not: a `--socket-path` on the
  command line satisfies it, and a validator sees only the file.
  `MinDelay <= MaxDelay` remains parser-only, because JSON Schema cannot compare
  two properties.

* The lower bounds on the boot libraries `bytestring`, `directory`, `filepath`,
  `text` and `time` are relaxed to the versions GHC 9.6.7 ships. That is the
  oldest compiler in `tested-with`. They were set to what the newest GHC ships,
  so a plan on 9.6 had to reinstall newer ones from Hackage. A downstream plan
  that cannot do that needed `allow-older` entries for all five. Only long
  stable API is used from them, and none of it is `OsPath`.

* The `ExperimentalHardForksEnabled` description in the JSON schemas now states
  that a `DijkstraGenesisFile` and `DijkstraGenesisHash` must accompany it. The
  schemas enforce that requirement too, with the `if`/`then` rule above.

## 1.1.0.0 -- 2026-09-08

Schema format version stays at `1`: the `v1` tag had not been cut when
`1.0.0.0` was released, so the constraint changes below are absorbed into it.
This is the last release that can do that — once `v1` is tagged, a change to
what validates needs a new format version.

### Breaking changes

* `NodeConfiguration` gains a `genesisInjectionRoot` field (the directory the
  ledger resolves genesis injection files against). The constructor is exported,
  so code building the record has to account for it (#17).
* The `LedgerDB` `Backend` key is now either the string `"V2InMemory"` or the
  tagged object `{ "LSM": { "DatabasePath": …, "ExportPath": … } }`. The flat
  spelling — `Backend: "V2LSM"` alongside `LSMDatabasePath`/`LSMExportPath` — is
  still accepted by the parser (`migrate` folds it into the tagged form, raising
  `MigratedToCurrentFormat`), but no longer validates against the schema (#14).
* `LedgerDbBackendSelector` now has its own `HasCodec` instance, and derives
  `Eq` (#14).
* The JSON under `defaults/` is compiled into the library with `file-embed`
  rather than installed as `data-files`. The `data-files` stanza is gone, so the
  defaults are no longer reachable through the Cabal data directory at run time;
  a distributed binary no longer needs one (#15).

### Added

* Genesis initial-data injection: a test network's genesis can name its initial
  funds, stake pools, stake credentials, delegations and DReps under the genesis
  `extraConfig` key, for `cardano-ledger` to stream from separate JSON files.
  New module `Cardano.Configuration.Genesis.Injection`, and from
  `Cardano.Configuration`: `nodeConfigurationInjectionFS`,
  `nodeConfigurationInjections`, `InjectionSlot (..)`, `InjectionSource (..)`,
  `injectionHasFS` and `injectionMountPoint`.

  Three conditions the ledger would otherwise report much later, while building
  the initial ledger state, are now checked as the configuration is read: a
  field takes its data from the legacy form or from `extraConfig`, never both;
  injection is rejected on a mainnet genesis; and a referenced injection file
  must exist. File hashes are left to the ledger, which verifies them as it
  streams (#17).
* `MaybeHashed (..)` is re-exported from `Cardano.Configuration` (#14).
* `Cardano.Configuration.Embedded`, exposing the embedded `defaults/`, and
  `decodeValueBytes` in `Cardano.Configuration.File.Merge` for decoding them
  (#15).
* `migrate` handles more legacy spellings: the flat `LedgerDB` snapshot options
  (`SnapshotInterval`, `NumOfDiskSnapshots`, …) are nested under
  `LedgerDB.Snapshots`, the flat `V2LSM` backend keys are folded into the tagged
  `Backend` form, and a top-level `ApplicationName` is collapsed into
  `HermodTracing.TraceOptionNodeName`. The obsolete `ApplicationVersion` and
  `EnableP2P` keys are now dropped rather than carried forward as
  unrecognised-key warnings (#14).

### Changed

* The `TxSubmissionInitDelay` default is now 60 seconds, was 0 (#14).

## 1.0.0.0 -- 2026-07-31

First release
