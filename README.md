# `cardano-config`

The single entry point for reading a `cardano-node` configuration. It provides:

- a CLI option parser (`parseCliArgs`),
- JSON/YAML configuration-file parsing (`parseConfigurationFiles`),
- resolution of the two into a `NodeConfiguration` (`resolveConfiguration`).

The goal is one shared parser for applications that need the node's configuration,
such as [`cardano-cli`](https://github.com/IntersectMBO/cardano-cli),
[`dmq-node`](https://github.com/IntersectMBO/dmq-node/) and
[the `ouroboros-consensus` tools](https://github.com/IntersectMBO/ouroboros-consensus/tree/main/ouroboros-consensus-cardano#consensus-db-tools).
The bundled `cardano-config` executable exposes the same via its `resolve` and
`schema` subcommands.

## Recommended format

A configuration is a single JSON/YAML object. The recommended form is the
**Version1 envelope**, with the components grouped under `Configuration`, each
given inline or as a path to a split sub-file:

```json
{
  "Version": 1,
  "MinNodeVersion": "10.5.0",
  "Configuration": {
    "ProtocolConfig": "variants/ProtocolConfig/mainnet.json",
    "StorageConfig": { "LedgerDB": { "Backend": "V2InMemory" } }
  }
}
```

Other shapes still parse, but raise a non-fatal warning: a document missing the
envelope (`NotVersion1Envelope`) or the legacy flat form with component keys at
the top level (`LegacySingleFileFormat`). See [Warnings](#warnings).

## Authoring with CUE

For typed authoring with editor- and CI-time checking, use the CUE front-end in
[`cue/`](cue/): you write the configuration as a CUE value, `just vet` / `just
lint` catch structural and cross-field mistakes early, and `cue export` emits the
envelope JSON this library ingests. The library stays the final authority (it
re-parses, fills defaults, and verifies genesis hashes). See
[`cue/README.md`](cue/README.md).

## Cookbook: I want to ...

The JSON snippets below use the recommended envelope form; the complete ones can
be passed straight to `--config` (a few show just the relevant fragment).

### ... run a relay node on mainnet with the default configuration

```json
{
  "Version": 1,
  "MinNodeVersion": "10.5.0",
  "Configuration": {
    "ProtocolConfig": "variants/ProtocolConfig/mainnet.json"
  }
}
```

(A node started without block-forging credentials resolves to the relay
networking defaults automatically.)

### ... run a block-producing node

A block producer is just a node given block-forging credentials. Supply them on
the CLI and the networking defaults switch to the block-producer peer targets and
disable `PeerSharing` automatically, with no `NetworkConfig` change required:

```console
$ cardano-config resolve --config mainnet.json \
    --shelley-kes-key kes.skey --shelley-vrf-key vrf.skey \
    --shelley-operational-certificate node.opcert
```

### ... override options in a component

A component is a single source: an inline object, or a string path to a sub-file.
Give it the keys you want set, and the component's base default (and, for
`NetworkConfig`, the credential-derived role layer) fills the rest:

```json
{
  "Version": 1,
  "MinNodeVersion": "10.5.0",
  "Configuration": {
    "ProtocolConfig": "variants/ProtocolConfig/mainnet.json",
    "NetworkConfig": { "TargetNumberOfRootPeers": 100 }
  }
}
```

There is no list / multi-source form. To combine a network variant with extra
overrides, merge them into one object yourself, or use the CUE front-end, which
unifies a preset with your overrides and emits the inlined result.

### ... reuse (and port) an existing single-file config

The historic flat form (every key at the top level, no envelope) still resolves
unchanged, so an existing `cardano-node` config keeps working, now with a
`LegacySingleFileFormat` / `NotVersion1Envelope` warning:

```console
$ cardano-config resolve --config mainnet-config.json
```

To port it, group the component keys under their sections inside `Configuration`
and add the `Version` / `MinNodeVersion` envelope. `cardano-config schema`
documents the recommended form; `--legacy-one-file` documents the flat form.

### ... see what my configuration resolves to, with defaults

```console
$ cardano-config resolve --config <your-config.json> --<other node CLI options>
ConsensusConfig:
  ConsensusMode: PraosMode
LocalConnectionsConfig:
  EnableRpc: false
NetworkConfig:
  ...
```

Add `--with-geneses` to also embed the decoded genesis of every era (large);
by default the genesis files appear only as a path and hash under `ProtocolConfig`.

### ... validate a config against the schema

The committed schemas (`schemas/`) are draft-07 and self-contained, so any
standard validator works, e.g. [`ajv`](https://github.com/ajv-validator/ajv-cli):

```console
$ ajv validate --spec=draft7 --strict=false -s schemas/config.schema.json -d my-config.json
```

This checks structure only, not genesis hashes or the cross-field rules; `resolve`
is the final check. The CUE front-end wires this up as `just ajv`.

### ... see the schema for a component (e.g. NetworkConfig)

```console
$ cardano-config schema NetworkConfig
{
    "$schema": "http://json-schema.org/draft-07/schema#",
    "description": "NetworkConfiguration",
    "properties": {
        "AcceptedConnectionsLimit": {
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
| Credentials | `--shelley-kes-key` *or* `--shelley-kes-agent-socket` | `FILEPATH` / `SOCKET_FILEPATH` | KES key source: a key file path **or** a KES Agent socket. Mutually exclusive. |
| Credentials | `--shelley-vrf-key`, `--shelley-operational-certificate`, `--bulk-credentials-file` | `FILEPATH` | Remaining Shelley credentials. |
| Credentials | `--start-as-non-producing-node` | | Start without block-production credentials. |
| Host | `--host-addr`, `--host-ipv6-addr` | `IPV4` / `IPV6` | Optional bind addresses. |
| Host | `--port` | `PORT` | Listening port (defaults to an ephemeral port). |
| Tracing | `--tracer-socket-network-accept`, `--tracer-socket-network-connect` | `HOST:PORT` | Connect to / accept a `cardano-tracer` over the network. |
| Tracing | `--tracer-socket-path-accept`, `--tracer-socket-path-connect` | `FILEPATH` | Connect to / accept a `cardano-tracer` over a local socket. |
| Shutdown | `--shutdown-ipc` | `FD` | Shut down when this inherited FD reaches EOF. |
| Shutdown | `--shutdown-on-slot-synced`, `--shutdown-on-block-synced` | `SLOT` / `BLOCK` | Shut down once the ChainDB is synced to the given target. |

`resolveConfiguration` combines `CliArgs` with the parsed file: where a CLI flag
overrides a file key (e.g. `--socket-path`, `--grpc-enable`, `--grpc-socket-path`),
the CLI value takes precedence and the file value is the fallback.

## What this library parses

The parsers are derived from
[`autodocodec`](https://hackage.haskell.org/package/autodocodec) codecs, and the
**authoritative key listing** (nested fields, defaults, validation) is the JSON
Schema derived from those same codecs. Dump it with the executable:

```console
$ cardano-config schema                    # the whole configuration (recommended form)
$ cardano-config schema --legacy-one-file  # the legacy single-file form (all keys flat)
$ cardano-config schema --list             # the available components
$ cardano-config schema StorageConfig      # one component
```

The schemas are also committed under [`schemas/`](schemas/) (the whole
configuration `config.schema.json`, its legacy counterpart, and one per
component). They are draft-07, declare a `type` for every scalar (`enum` for
string enumerations), flag filesystem paths with `"format": "path"`, and carry
`title`/`$id` for documentation tooling. The test-suite asserts they match the
codecs (so they cannot drift); regenerate them with `scripts/gen-schemas.sh`.

The recognised keys are grouped into the following components. Every component may
be given inline or as a sub-file path (see
[Inline and split components](#inline-and-split-components)).

| Component | Top-level keys |
| --- | --- |
| **StorageConfig** | `DatabasePath`, `LedgerDB` (`Snapshots`, `QueryBatchSize`, `Backend` = `V2InMemory`/`V2LSM`, `LSMDatabasePath`, `LSMExportPath`) |
| **ConsensusConfig** | `ConsensusMode` (`PraosMode`/`GenesisMode`), `LowLevelGenesisOptions` (`EnableCSJ`, `EnableLoEAndGDD`, `EnableLoP`, `BlockFetchGracePeriod`, `BucketCapacity`, `BucketRate`, `CSJJumpSize`, `GDDRateLimit`) - Genesis mode only |
| **ProtocolConfig** | `ByronGenesisFile`/`ByronGenesisHash`, `RequiresNetworkMagic`, `PBftSignatureThreshold`, `LastKnownBlockVersion-Major`/`-Minor`/`-Alt`, `ShelleyGenesisFile`/`Hash`, `AlonzoGenesisFile`/`Hash`, `ConwayGenesisFile`/`Hash`, `StartAsNonProducingNode`, `CheckpointsFile`/`CheckpointsFileHash` |
| **NetworkConfig** | `DiffusionMode`, `MaxConcurrencyBulkSync`, `MaxConcurrencyDeadline`, `ProtocolIdleTimeout`, `TimeWaitTimeout`, `EgressPollInterval`, `ChainSyncIdleTimeout`, `AcceptedConnectionsLimit`, the `TargetNumberOf*`/`SyncTargetNumberOf*` peer targets, `MinBigLedgerPeersForTrustedState`, `PeerSharing`, `ResponderCoreAffinityPolicy`, `ExperimentalProtocolsEnabled`, `TxSubmissionLogicVersion`, `TxSubmissionInitDelay` |
| **LocalConnectionsConfig** | `SocketPath`, `EnableRpc`, `RpcSocketPath` |
| **MempoolConfig** | `MempoolCapacityBytesOverride`, `MempoolTimeoutSoft`, `MempoolTimeoutHard`, `MempoolTimeoutCapacity` |
| **TestingConfig** | `ExperimentalHardForksEnabled`, the `Test<Era>HardForkAtEpoch`/`Test<Era>HardForkAtVersion` knobs (Shelley .. Dijkstra), `DijkstraGenesisFile`/`DijkstraGenesisHash` |

Tracing is **not** parsed: it is owned by the node's tracing system (hermod /
`trace-dispatcher`) and given under a single top-level `HermodTracing` key whose
value is a path to a separate file. The key is recognised and captured opaquely
(it appears in the schema), but its contents are not interpreted here. The
authoritative schema lives in
[`hermod-tracing`](https://github.com/IntersectMBO/hermod-tracing).

### Mandatory vs optional keys

Only **six** keys are mandatory (no default; parsing fails if absent):
`ByronGenesisFile`, `ShelleyGenesisFile`, `AlonzoGenesisFile`, `ConwayGenesisFile`,
`LastKnownBlockVersion-Major` and `LastKnownBlockVersion-Minor`. These are
network-specific, so they are deliberately not in the base defaults; supply them
directly or by referencing a
`variants/ProtocolConfig/<network>.json` file.

**Every other key is optional**: it either has a default (from the `defaults/`
layer, see [Defaults and layering](#defaults-and-layering)) or is optional by
nature ("unset" is valid: the `*Hash` keys, `PBftSignatureThreshold`,
`CheckpointsFile`, `SocketPath`/`RpcSocketPath`, `MempoolCapacityBytesOverride`,
`DijkstraGenesisFile`, the `Test<Era>HardForkAt*` knobs).

A few groups are resolved by a cross-field rule rather than plain layering:

- the **deadline peer targets** (`TargetNumberOf*`) and `PeerSharing` default to
  the block-producer or relay values depending on whether block-forging
  credentials were supplied; an explicit value still wins.
- the three **mempool timeouts** (`MempoolTimeoutSoft`/`Hard`/`Capacity`) are
  all-or-nothing: give all three or none. All-unset takes the coupled default of
  `(1, 1.5, 5)` seconds; a partial set is rejected.
- the **snapshot policy** (`LedgerDB.Snapshots`) accepts the named `"Mithril"`
  policy or an options object, and resolution expands it to a concrete set
  (`"Mithril"` to its fixed values; a partial object inherits the rest), exposed
  via `mithrilSnapshotOptions` / `resolveSnapshotPolicy`. Under `V2LSM`,
  `LSMDatabasePath` defaults to `lsm`; the Mithril policy under `V2LSM` without an
  `LSMExportPath` is accepted with a `ConsistencyWarning`.

## Warnings

`parseConfigurationFiles` and `resolveConfiguration` return the parsed/resolved
value **together with a list of `ConfigWarning`s** rather than printing or failing
on them, so each consumer decides how to surface them (the executable prints them
to `stderr`; `renderConfigWarning` gives the default text; a stricter caller can
treat them as fatal). The warnings are:

- `NotVersion1Envelope` - the document is not in the recommended
  `{ Version, MinNodeVersion, Configuration }` envelope form (names the missing keys);
- `LegacySingleFileFormat` - component keys appear flat at the top level instead
  of grouped per section;
- `UnrecognisedKeys` - top-level keys no parser claims (typically typos; ignored);
- `ShadowedKeys` - a component given as its own section *and* one of its keys also
  at the top level; the top-level value is ignored (the section wins);
- `ConsistencyWarning` - a resolution-time consistency advisory (e.g. Mithril
  under `V2LSM` without an `LSMExportPath`).

## Inline and split components

Within `Configuration`, each component is either an inline object or a string path
to a sub-file (relative to the main config file, confined to its directory):

```json
"Configuration": {
  "ProtocolConfig": "protocol.json",
  "StorageConfig": { "LedgerDB": { "Backend": "V2InMemory" } }
}
```

The section keys are suffixed `Config` (`ProtocolConfig`, not `Protocol`) on
purpose: the node has a vestigial top-level `Protocol` scalar (only ever
`"Cardano"`), so a bare `Protocol` key would clash. The legacy single-file form
(all keys flat at the top level, no `Configuration` wrapper) is still accepted but
warns; `cardano-config schema --legacy-one-file` documents it.

## Defaults and layering

Every component ships a **default file** under [`defaults/`](defaults/), with the
network/role overlays under [`variants/`](variants/). For each component the
layering, from lowest to highest precedence, is:

1. the package's base default (`defaults/<Component>.json`), always applied;
2. for the `Network` component only, a **role layer** chosen automatically from
   credential presence: the block-producer or relay variant
   (`variants/NetworkConfig/{blockproducer,relay}.json`)
   fills the deadline peer targets and `PeerSharing` when the configuration leaves
   them unset (so it sits *below* the file value);
3. the component's value in the configuration file (an inline object or a sub-file
   path, including any `variants/<Component>/*` overlay the configuration
   references explicitly);
4. the matching CLI flag, where one exists.

The role layer applies the same values the variant files hold, so referencing a
variant explicitly and letting the credential-derived default apply give the same
result.

`cardano-config` is the *origin* of these default files, but each is ultimately
owned by the layer that implements the component (networking, consensus, ...); a
CI check keeps the copies here aligned with upstream.
