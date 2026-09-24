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
  rather than the pair, with `renderMigrationError` for the message.

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
  schema, instead of "a file path or that schema". In the library,
  `splitConfigSchema` and `splitConfigSchemaWithDefaults` become `configSchema`
  and `configSchemaWithDefaults`.

* There is one schema. The legacy single-file schema is gone, with it
  `schema --legacy-one-file`, `schemas/config.legacy-one-file.schema.json`,
  `legacyOneFileConfigSchema`, `legacyOneFileConfigSchemaWithDefaults` and
  `Cardano.Configuration.Commands.ConfigForm`. It described a form that
  `migrate` exists to convert away from, so nothing needed it.
  `cardano-config schema` now takes no options, and `schemaOptionsParser` has
  type `Parser ()`.

* The `variants/` directory is gone. Its files held per-network sections to
  copy by hand. Nothing read them, and with the split-file form removed a
  configuration could not point at one either. Copy the genesis names for your
  network out of a working configuration instead.

* The package ships two default configurations instead of one file per
  component: `defaults/config.blockproducer.json` and
  `defaults/config.relay.json`. Each is a complete configuration in the
  envelope, holding every component's defaults, and the two differ only in the
  `NetworkConfig` deadline peer targets and `PeerSharing`. The seven
  `defaults/<Component>.json` files, `defaults/HermodTracing.json` and
  `defaults/NetworkConfig/{blockproducer,relay}.json` are gone. Because one
  file now holds every component's defaults, no component team can own its own
  defaults file: CODEOWNERS gives `defaults/` to all of them.

* The defaults are applied at resolution, not while the file is read. Which
  ones apply depends on the node's role, and the role comes from the command
  line, so the merge belongs where the command line is:
  `resolveConfiguration` now picks the role's default configuration, merges
  your configuration on top and reads each section from the result.

  `parseConfigurationFiles` therefore returns what the file said, with nothing
  filled in. `NodeConfigurationFromFile` keeps its seven parsed component
  fields, but each now holds the file's own values rather than the file merged
  over the defaults, so a field the file leaves unset is `SNothing`. It loses
  `networkUserLayer`, which existed only to carry that same distinction, and
  gains `userConfiguration :: Value`, the `Configuration` object as JSON.

  Resolution merges the role's defaults under that JSON and reads the
  components from the result. The merge recurses into nested objects, so a
  file that sets one field of `LedgerDB` keeps the defaults of the others.
  Merging the typed components field by field would replace whole nested
  objects instead, which is why the JSON is carried alongside.

  `Cardano.Configuration.File.Merge` swaps `loadBaseDefault` for
  `defaultConfiguration :: BlockProducerOrRelay -> Value`, and gains
  `decodeSection`, the pure section reader resolution uses.

  The layering it replaces was `base < role < user` with the role slotted in
  between (`withRoleDefaults`), which is why the user's layer had to be carried
  separately. `withRoleDefaults`, `networkRoleDefaults`,
  `blockProducerRoleDefaults`, `relayRoleDefaults` and
  `emptyNetworkConfiguration` are all gone; the role values live in the two
  data files alone. The result is unchanged: the role overlay never touched a
  field the base set, so folding it in layers identically.

* The per-component schemas are gone: `schemas/<Component>.schema.json`, the
  `schema <COMPONENT>` argument and `schema --list`. Each was that section of
  `config.schema.json` and nothing else, bar its own `$id` and `$schema`, and
  with the split-file form removed nothing writes a standalone component
  document.
  `configurationSchemas`, `configurationSchemasWithDefaults` and the seven
  `storageSchema`-style values go with them, and `componentDefaults` is now a
  pure value rather than an `IO` action. The `$schema` lines in the
  per-component test fixtures, which pointed at those URLs, are removed.

* The schema states every default the library applies. `GrpcListenAddress`
  gains `default: "127.0.0.1"`, taken from `defaultGrpcListenAddress` itself so
  the two cannot drift. It cannot come from the defaults files: a value there
  reaches every configuration, and an address without a port is rejected, so
  every configuration that sets no port would stop parsing.

  Two defaults stay in their descriptions rather than in a `default` keyword,
  because JSON Schema cannot express either. The mempool timeouts are one
  coupled default of three values, applied only when all three are unset, and
  the LSM `DatabasePath` default of `"lsm"` applies only under the LSM
  backend. `DatabasePath` is also the one property name that is not unique in
  the configuration, so the by-name annotation could not reach it anyway.

* The configuration schema describes the envelope and only the envelope. It
  used to put the section keys at the *top* level, beside `Version`, and
  declare `Configuration` as a bare `{"type": "object"}` — so it validated a
  shape nothing recommends and let anything at all through inside the envelope.
  A document with a partial mempool timeout set validated against it. The
  sections now sit under `Configuration`, where the parser reads them, and
  `$schema`, `Version` and `Configuration` are required, so a legacy document
  fails validation as the README has always said it should. Those three are
  exactly what `migrate` always writes: a document missing any of them is one
  migration would change, which the parser already reports as
  `OutdatedFormatVersion` or `MigratedToCurrentFormat`. `MinNodeVersion` stays
  optional, because `migrate` never invents one.

  This is a change to what validates. The cross-field rules it now reaches
  reject only documents the parser already rejected, but requiring the
  envelope rejects one it accepts: a legacy document still parses, because
  `migrate` rewrites it first, and fails validation all the same. That split
  is deliberate — the schema documents the current form alone.

* `NodeConfigurationFromFile` is a plain record: `NodeConfigurationFromFileF`
  and its `Identity` type synonym are gone, and the constructor is
  `NodeConfigurationFromFile`, not `NodeConfigurationFromFileV1`. The `f`
  parameter staged a component that might still be a sub-file reference
  against one already read, so with no sub-files it had one stage and nothing
  left to say. The component fields it wrapped are gone as well (above), so
  there is no `runIdentity` to drop — there are fields to stop reading.

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

* The consistency check on enabling gRPC now requires a node socket path,
  whatever the gRPC server listens on. The server serves every request over
  the node-to-client socket, so a TCP listener changes where it listens, not
  whether it needs that socket, and `cardano-node`'s `makeRpcConfig` refuses
  `EnableGrpc` without a socket path in every case.

  The old check accepted `EnableGrpc` with a `GrpcSocketPath` and no
  `SocketPath`, which `cardano-node` then rejected at startup; extending it to
  the new TCP and TLS listeners would have widened that gap. Requiring the
  socket path closes both. A configuration that enables gRPC and names no node
  socket path now fails to resolve, and the check's `checkDescription` says
  why. `test/examples/version1.json` was one such configuration and gains a
  `SocketPath`.

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
  Nothing is said about the ignored file either, deliberately: turning the flag
  on hard-forks the node onto an experimental era, which is coordinated across
  a network, so no message here should read as a nudge towards doing it.

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

* The numeric command-line options take plain decimal only. They read through
  `readEither`, which also accepts Haskell's hexadecimal and octal literals and
  surrounding whitespace, so `--grpc-listen-port 0x1F1` bound port 497 and
  `0o17` bound port 15, quietly. `cardano-node` rejects both (its
  `parsePortNumber` filters on `isDigit` first). This affects every option
  using the shared `bounded` reader: `--port`, `--grpc-listen-port`,
  `--shutdown-on-slot-synced` and `--shutdown-on-block-synced`.

* The peer selection targets are checked at resolution, and a set
  `ouroboros-network` will not accept is now rejected. The check calls that
  library's own `sanePeerSelectionTargets`, so the two cannot disagree: each of
  the active, established and known targets must be no greater than the next,
  the root target no greater than the known target, the same order must hold
  among the three big ledger peer targets, none may be negative, and the
  active, established and known targets are capped at 100, 1000 and 10000. The
  `Deadline` and `Sync` groups are checked separately, so the failure names
  which seven fields are meant.

  The node does not reject such a set itself. Its peer selection governor
  states the invariant as an assertion, which `-O` compiles out, so a release
  node starts and runs peer selection on targets that logic is written assuming
  cannot occur. A configuration the node ran correctly before is unaffected.

  This adds `ouroboros-network` to the library's dependencies.
  `Cardano.Configuration.File.Network` gains `deadlinePeerSelectionTargets` and
  `syncPeerSelectionTargets`, which build that library's `PeerSelectionTargets`
  from a resolved configuration. The deadline one returns `Maybe`: those seven
  targets have no always-applied default, and a configuration stating only some
  of them describes no target set, so it is passed on unchecked.

* `cardano-config` no longer supplies tracing defaults. Tracing belongs to
  `trace-dispatcher`, which falls back on its own for whatever a configuration
  leaves unset, so `HermodTracing` is now handed to it as written, with no
  default under it. `defaultCardanoTracingConfig` is gone from
  `Cardano.Configuration.File`, and a configuration with no `HermodTracing` key
  gets `mkConfiguration` (re-exported there) instead of it.

  That literal set more than the fallback does: the `EKGBackend` backend, the
  `cardano.node.metrics.` metrics prefix, per-tracer severities for `ChainDB`,
  `Mempool`, `Forge` and others, and five rate limiters. None of them apply
  now. A node that wants them must say so under `HermodTracing`. The fallback
  that remains is `Notice` severity, `DNormal` detail and `Stdout
  MachineFormat` at the namespace root.

  The `HermodTracing` block in `defaults/config.blockproducer.json` and
  `defaults/config.relay.json` states that fallback, but is not applied: unlike
  every other section there, it is shown rather than used. The test suite pins
  it to what `trace-dispatcher` falls back to, so it cannot drift.

### Added

* `migrate` rewrites the remaining `Rpc*` key names to their `Grpc*` form:
  `RpcListenAddress`, `RpcListenPort`, `RpcTlsCertificateFile`,
  `RpcTlsPrivateKeyFile` and `RpcTlsChainCertificateFiles`, alongside the
  `EnableRpc`/`RpcSocketPath` pair it already handled.

  The schemas gain the new keys, and `migrate` now stamps `Version: 2` on the
  documents it reshapes, replacing an older one (see the breaking change
  above). A `Version` *newer* than 2 is left alone, because migration never
  goes backwards, and a `$schema` is kept only on a document whose version
  migration did not move.

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
  "Enabling gRPC needs a node socket path" is not: a `--socket-path` on the
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
