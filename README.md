# `cardano-config`

This package exposes a library that defines:

- A parser for CLI options based on `optparse-applicative` (see `parseCliArgs`).

- Instances for parsing the configuration files from JSON/YAML (see `parseConfigurationFiles`).

- A function (`resolveConfiguration`) for combining the two above into a
  datatype representing the configuration of the `cardano-node` (`NodeConfiguration`).

The goal of this library is to offer a single entry-point for applications that
need access to the configuration file of the node, such as [`cardano-cli`](https://github.com/IntersectMBO/cardano-cli),
[`dmq-node`](https://github.com/IntersectMBO/dmq-node/), [the `ouroboros-consensus` tools](https://github.com/IntersectMBO/ouroboros-consensus/tree/main/ouroboros-consensus-cardano#consensus-db-tools), ...

## Cookbook: I want to ...

### ... run a relay node on mainnet with the default configuration

```json
{
  "ProtocolConfig": "ProtocolConfig.variants/ProtocolConfig.mainnet.json",
  "NetworkConfig": "NetworkConfig.variants/NetworkConfig.relay.json"
}
```

### ... override a single specific option

```json
{
  "ProtocolConfig": "ProtocolConfig.variants/ProtocolConfig.mainnet.json",
  "NetworkConfig": ["NetworkConfig.variants/NetworkConfig.relay.json", { "TargetNumberOfRootPeers": 100 } ]
}
```

### ... override many options in a component

```json
{
  "ProtocolConfig": "ProtocolConfig.variants/ProtocolConfig.mainnet.json",
  "NetworkConfig": ["NetworkConfig.variants/NetworkConfig.relay.json", "my-custom-networking-options.json" ]
}
```

### ... see what my current configuration resolves to, with defaults

```console
$ cardano-config resolve --config <your-config.json> --<other node CLI options>
ConsensusConfig:
  ConsensusMode: PraosMode
LocalConnectionsConfig:
  EnableRpc: false
MempoolConfig:
  MempoolCapacityBytesOverride: NoOverride
NetworkConfig:
  AcceptedConnectionsLimit:
    delay: 5
    hardLimit: 512
    softLimit: 384
  ChainSyncIdleTimeout: 3373
...
```

### ... see the schema for a component (e.g. NetworkConfig)

```console
$ cardano-config schema NetworkConfig
{
    "$id": "https://raw.githubusercontent.com/IntersectMBO/cardano-base/master/cardano-config/schemas/NetworkConfig.schema.json",
    "$schema": "http://json-schema.org/draft-07/schema#",
    "description": "NetworkConfiguration",
    "properties": {
        "AcceptedConnectionsLimit": {
...
```

### ... modify my configuration and check that it is well-formed

```console
$ cat <your-config.json> | jq '...' > <your-updated-config.json>
$ cardano-config resolve --config <your-config.json> --<other node CLI options>
ConsensusConfig:
  ConsensusMode: PraosMode
LocalConnectionsConfig:
  EnableRpc: false
...
```

## CLI options

`parseCliArgs` is an `optparse-applicative` parser producing a `CliArgs` value.
The flag names, metavars and help text match those historically accepted by
`cardano-node`, so existing operator scripts keep working. The recognised flags
are:

| Group | Flag(s) | Metavar | Notes |
| --- | --- | --- | --- |
| | `--config` | `FILEPATH` | Main configuration file (defaults to `./configuration/cardano/mainnet-config.json`). |
| | `--topology` | `FILEPATH` | Topology file (defaults to the mainnet `./configuration/cardano/mainnet-topology.json`). |
| | `--socket-path` | `FILEPATH` | Socket for local clients; overrides `LocalConnectionsConfig.SocketPath`. |
| | `--grpc-enable` | | [EXPERIMENTAL] Enable the gRPC endpoint; overrides `LocalConnectionsConfig.EnableRpc`. Absent means *unset* (falls back to the config file), not `False`. |
| | `--grpc-socket-path` | `FILEPATH` | [EXPERIMENTAL] gRPC socket path; overrides `LocalConnectionsConfig.RpcSocketPath`. Defaults to `rpc.sock` next to the node socket. |
| Storage | `--database-path`, `--volatile-database-path`, `--immutable-database-path` | `FILEPATH` | Overrides `StorageConfig.DatabasePath`. |
| Storage | `--validate-db` | | Validate all on-disk database files. |
| Credentials | `--byron-delegation-certificate`, `--byron-signing-key` | `FILEPATH` | Byron operational credentials. |
| Credentials | `--shelley-kes-key` *or* `--shelley-kes-agent-socket` | `FILEPATH` / `SOCKET_FILEPATH` | KES key source — a key file path **or** a KES Agent socket. Mutually exclusive. |
| Credentials | `--shelley-vrf-key`, `--shelley-operational-certificate`, `--bulk-credentials-file` | `FILEPATH` | Remaining Shelley credentials. |
| Credentials | `--start-as-non-producing-node` | | Start without block-production credentials. |
| Host | `--host-addr`, `--host-ipv6-addr` | `IPV4` / `IPV6` | Optional bind addresses. |
| Host | `--port` | `PORT` | Listening port (defaults to an ephemeral port). |
| Tracing | `--tracer-socket-network-accept`, `--tracer-socket-network-connect` | `HOST:PORT` | Connect to / accept a `cardano-tracer` over the network. |
| Tracing | `--tracer-socket-path-accept`, `--tracer-socket-path-connect` | `FILEPATH` | Connect to / accept a `cardano-tracer` over a local socket. |
| Shutdown | `--shutdown-ipc` | `FD` | Shut down when this inherited FD reaches EOF. |
| Shutdown | `--shutdown-on-slot-synced`, `--shutdown-on-block-synced` | `SLOT` / `BLOCK` | Shut down once the ChainDB is synced to the given target. |

`resolveConfiguration` combines `CliArgs` with the parsed file: where a CLI flag
overrides a file key (e.g. `--socket-path`, `--grpc-enable`,
`--grpc-socket-path`), the CLI value takes precedence and the file value is the
fallback.

## What this library parses

The configuration is a single JSON/YAML object. The parsers are derived from
[`autodocodec`](https://hackage.haskell.org/package/autodocodec) codecs, and the
**authoritative, always-up-to-date key listing** (including nested fields,
defaults and validation) is the JSON Schema derived from those very codecs. Dump
it with the bundled `cardano-config` executable's `schema` subcommand:

```console
$ cardano-config schema                  # the whole configuration (split-file form)
$ cardano-config schema --legacy-one-file # the legacy single-file form (all keys flat)
$ cardano-config schema --list           # the available components
$ cardano-config schema StorageConfig    # one component
```

The default `schema` output is the **split-file form** — each component under its
section key — which is the form new configurations should use and is far simpler
than one schema covering every form at once. The older single-file form (every
key flat at the top level) is still accepted by the parser; its schema is
available under `--legacy-one-file`.

The generated schemas are also committed under [`schemas/`](schemas/) — the
split-file whole configuration (`schemas/config.schema.json`), its legacy
single-file counterpart (`schemas/config.legacy-one-file.schema.json`) and one
per component (`schemas/<Component>.schema.json`). The test-suite asserts they
match the codecs (so they cannot drift); regenerate them with
`scripts/gen-schemas.sh`.

The schemas are draft-07 and post-processed to be as useful as possible:

- every scalar field declares a `type`; string enumerations use `enum`;
- a field that is a filesystem path keeps `"type": "string"` but adds
  `"format": "path"` (JSON Schema has no dedicated path type, so `format` is the
  standard way to flag one), so tooling can treat paths specially;
- every schema and property carries a `title`, and every document an `$id`, so
  documentation generators such as
  [`jsonschema2md`](https://github.com/adobe/jsonschema2md) render names instead
  of `Untitled`/`undefined` (both keywords are standard draft-07, not extensions);
- `config.schema.json` describes the **split-file form** (each component given
  under its section key as a sub-file path, an inline object, or a list of them),
  plus the `{ Version, Configuration }` envelope. The flat single-file form lives
  in its own `config.legacy-one-file.schema.json` (which predates, and so omits,
  the envelope). Splitting the two forms is what lets each schema drop the
  "section key *xor* top-level keys" exclusivity rules that a combined schema
  needs.

To see the *resolved* configuration for a given file — the per-component
defaults and the configuration file, plus the CLI flags, all merged and resolved
exactly as the node does it
— use the `cardano-config` executable's `resolve` subcommand. It accepts the same
flags as the node (`--config` selects the file) and prints the result as YAML,
using the same documented keys as the input (each component under its name, with
the CLI-only operational arguments grouped under `Runtime`):

```console
$ cardano-config resolve --config mainnet-config.yaml
```

By default the genesis files appear only as their path and hash (under
`ProtocolConfig`). Pass `--with-geneses` to additionally embed the decoded
genesis value of every era (`ByronGenesis`, `ShelleyGenesis`, `AlonzoGenesis`,
`ConwayGenesis`, and `ExperimentalGenesis` when present) — these are the very
files that were read and hash-checked while parsing:

```console
$ cardano-config resolve --config mainnet-config.yaml --with-geneses
```

(The library exposes this rendering as `nodeConfigurationToJSON` in
`Cardano.Configuration.Render`; its `GenesisRendering` argument selects whether
the genesis values are included.)

Keys that none of the parsers below recognise produce a **warning** by default
(so typos are noticed); `parseConfigurationFilesWith RejectUnknownKeys` turns
them into a hard error instead.

The same policy governs **shadowed keys**: if a component is given as its own
section (e.g. a `TestingConfig` section key) *and* one of that component's keys also
appears at the top level (e.g. a top-level `DijkstraGenesisFile`), the top-level
value is ignored — the section wins. That is almost always a mistake, so it
warns by default and is rejected under `RejectUnknownKeys`. (This concerns only
the keys you write; the per-component defaults are merged separately and never
trigger it.)

The shadowed-key check is a runtime one: the split-file and legacy schemas are
kept separate precisely so that neither even *offers* both placements for a
component (the split schema exposes only section keys, the legacy schema only the
flat keys), which is what lets each schema stay simple. Mixing the two forms is
therefore caught by the parser rather than by a generic JSON Schema validator.

The recognised keys are grouped into the following components. Every component
may be given inline, as a sub-file path, or as a list of sources (see
[Single-file and split forms](#single-file-and-split-forms)).

| Component | Top-level keys |
| --- | --- |
| **StorageConfig** | `DatabasePath`, `LedgerDB` (`Snapshots`, `QueryBatchSize`, `Backend` = `V2InMemory`/`V2LSM`, `LSMDatabasePath`, `LSMExportPath`) |
| **ConsensusConfig** | `ConsensusMode` (`PraosMode`/`GenesisMode`), `LowLevelGenesisOptions` (`EnableCSJ`, `EnableLoEAndGDD`, `EnableLoP`, `BlockFetchGracePeriod`, `BucketCapacity`, `BucketRate`, `CSJJumpSize`, `GDDRateLimit`) — Genesis mode only |
| **ProtocolConfig** | `ByronGenesisFile`/`ByronGenesisHash`, `RequiresNetworkMagic`, `PBftSignatureThreshold`, `LastKnownBlockVersion-Major`/`-Minor`/`-Alt`, `ShelleyGenesisFile`/`Hash`, `AlonzoGenesisFile`/`Hash`, `ConwayGenesisFile`/`Hash`, `StartAsNonProducingNode`, `CheckpointsFile`/`CheckpointsFileHash` |
| **NetworkConfig** | `DiffusionMode`, `MaxConcurrencyBulkSync`, `MaxConcurrencyDeadline`, `ProtocolIdleTimeout`, `TimeWaitTimeout`, `EgressPollInterval`, `ChainSyncIdleTimeout`, `AcceptedConnectionsLimit`, the `TargetNumberOf*`/`SyncTargetNumberOf*` peer targets, `MinBigLedgerPeersForTrustedState`, `PeerSharing`, `ResponderCoreAffinityPolicy`, `ExperimentalProtocolsEnabled`, `TxSubmissionLogicVersion`, `TxSubmissionInitDelay` |
| **LocalConnectionsConfig** | `SocketPath`, `EnableRpc`, `RpcSocketPath` |
| **MempoolConfig** | `MempoolCapacityBytesOverride`, `MempoolTimeoutSoft`, `MempoolTimeoutHard`, `MempoolTimeoutCapacity` |
| **TestingConfig** | `ExperimentalHardForksEnabled`, the `Test<Era>HardForkAtEpoch`/`Test<Era>HardForkAtVersion` knobs (Shelley … Dijkstra), `DijkstraGenesisFile`/`DijkstraGenesisHash` |

### Mandatory vs optional keys

Only **six** keys are mandatory — they have no default and parsing fails if they
are absent:

- `ByronGenesisFile`
- `ShelleyGenesisFile`
- `AlonzoGenesisFile`
- `ConwayGenesisFile`
- `LastKnownBlockVersion-Major`
- `LastKnownBlockVersion-Minor`.

These are network-specific, so they are deliberately *not* in the base defaults;
supply them either directly in your configuration or by referencing a
`ProtocolConfig.variants/ProtocolConfig.<network>.json` file (which provides them for that
network).

**Every other key is optional**: it either has a default (applied from the
`defaults/` layer — see [Defaults and layering](#defaults-and-layering)) or is
optional by nature, meaning "unset" is a valid state (the `*Hash` keys,
`PBftSignatureThreshold`, `CheckpointsFile`,
`SocketPath`/`RpcSocketPath`, `MempoolCapacityBytesOverride`, the experimental
`DijkstraGenesisFile`, and the `Test<Era>HardForkAt*` knobs).

Three groups of keys are resolved by a cross-field rule rather than plain
layering:

- the **deadline peer targets** (`TargetNumberOf*`) and `PeerSharing` default to
  the block-producer or relay values depending on whether block-forging
  credentials were supplied; an explicit value still wins. See
  [Defaults and layering](#defaults-and-layering).
- the three **mempool timeouts** (`MempoolTimeoutSoft`/`Hard`/`Capacity`) are
  all-or-nothing: give all three or none. All-unset takes the coupled default of
  `(1, 1.5, 5)` seconds; a partial set is rejected.
- the **snapshot policy** (`LedgerDB.Snapshots`) accepts either the named
  `"Mithril"` policy or an options object. Resolution expands it to a concrete
  set of options: `"Mithril"` becomes its fixed values, and an options object
  that sets only some fields inherits the rest from the Mithril values — so a
  resolved configuration always has every snapshot option set. (Consumers can
  reuse the values directly via `mithrilSnapshotOptions` /
  `resolveSnapshotPolicy`.)

### Tracing is *not* parsed

Tracing is owned by the node's tracing system (hermod / `trace-dispatcher`), not
by this library. It is given under a single top-level `HermodTracing` key, whose
value is a path (a string) to a separate file holding it — it is *not* a section
of its own. The key is recognised and captured **opaquely**: it appears in the
schema (as a `HermodTracing` path) so that users can see it exists, but its
contents are neither interpreted nor validated here. The authoritative schema for
them lives in [`hermod-tracing`](https://github.com/IntersectMBO/hermod-tracing).

## Single-file and split forms

### Single-file

In the **single-file form**, all of the keys above live directly at the top level
of one object:

```console
$ cat config.json
{
    "ConsensusMode": "PraosMode",
    "ByronGenesisFile": "byron-genesis.json",
    "LastKnownBlockVersion-Major": 3,
    "LastKnownBlockVersion-Minor": 0,
    "ShelleyGenesisFile": "shelley-genesis.json",
    "LedgerDB": {
        "Backend": "V2InMemory",
        "NumOfDiskSnapshots": 2,
        "QueryBatchSize": 100000,
        "SnapshotInterval": 4320
    }
}
```

### Split form

Alternatively, any component (`StorageConfig`, `ConsensusConfig`, `ProtocolConfig`, `NetworkConfig`,
`LocalConnectionsConfig`, `MempoolConfig`, `TestingConfig`) may be **split into a sub-file**: give
the component key a string path (relative to the main config file) instead of an
inline object.

> The section keys are suffixed `Config` (`ProtocolConfig`, not `Protocol`) on
> purpose: the node has a vestigial top-level `Protocol` scalar (only ever
> `"Cardano"`), so a bare `Protocol` section key would clash with it. See
> [`defaults/README.md`](defaults/README.md) for the vestigial keys
> (`Protocol`, `MaxKnownMajorProtocolVersion`) this library does not parse.

```console
$ cat config.json
{
    "ProtocolConfig": "protocol.json",
    "StorageConfig": "storage.json"
}
$ cat storage.json
{
    "LedgerDB": {
        "Backend": "V2InMemory",
        "NumOfDiskSnapshots": 2,
        "QueryBatchSize": 100000,
        "SnapshotInterval": 4320
    }
}
```

A component key may also hold a **list** of sources (paths and/or inline
objects), which are deep-merged in order — a later entry overrides an earlier one,
and nested objects merge recursively:

```console
$ cat config.json
{
    "NetworkConfig": ["NetworkConfig.variants/NetworkConfig.relay.json", { "PeerSharing": false }]
}
```

## Versioning

The configuration may optionally be wrapped in an envelope so the format can
evolve:

```json
{ "Version": 1, "Configuration": { ... } }
```

A document without an envelope is read as version 1 (the keys live at the top
level), so existing configurations keep working.

## Defaults and layering

Every component ships a **default file** under [`defaults/`](defaults/) (see
[`defaults/README.md`](defaults/README.md)). For each component the layering,
from lowest to highest precedence, is:

1. the package's base default (`defaults/<Component>.json`), always applied;
2. for the `Network` component only, a **role layer** chosen automatically from
   credential presence: the block-producer or relay variant
   (`defaults/NetworkConfig.variants/NetworkConfig.{blockproducer,relay}.json`)
   fills the deadline peer targets and `PeerSharing` when the configuration
   leaves them unset (so it sits *below* the file value);
3. the component's value in the configuration file (an inline object, a sub-file
   path, or a list of them merged in order — including any
   `defaults/<Component>.variants/*` overlays the configuration chooses to
   reference explicitly);
4. the matching CLI flag, where one exists.

The role layer applies the same values the variant files hold, so referencing a
variant explicitly and letting the credential-derived default apply give the same
result.

`cardano-config` is the *origin* of these default files, but each is ultimately
owned by the layer that implements the component (networking, consensus, …); a CI
check keeps the copies here aligned with upstream.
