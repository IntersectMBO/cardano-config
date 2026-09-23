# `cardano-config`

The single entry point for reading a `cardano-node` configuration. It provides:

- a CLI option parser (`parseCliArgs`),
- JSON/YAML configuration-file parsing (`parseConfigurationFiles`),
- resolution of the two into a `NodeConfiguration` (`resolveConfiguration`).

The goal is one shared parser for applications that need the node's configuration,
such as [`cardano-cli`](https://github.com/IntersectMBO/cardano-cli),
[`dmq-node`](https://github.com/IntersectMBO/dmq-node/) and
[the `ouroboros-consensus` tools](https://github.com/IntersectMBO/ouroboros-consensus/tree/main/ouroboros-consensus-cardano#consensus-db-tools).
The bundled `cardano-config` executable exposes the same via its `resolve`,
`schema` and `migrate` subcommands.

## Recommended format

A configuration is **one** JSON/YAML object, in one file. The recommended form
is the **versioned envelope**: `$schema` (the URL of the schema the file
follows), `Version` and `MinNodeVersion` at the top level, with the components
grouped under `Configuration`, each given inline:

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/v2/schemas/config.schema.json",
  "Version": 2,
  "MinNodeVersion": "11.2",
  "Configuration": {
    "ProtocolConfig": {
      "RequiresNetworkMagic": "RequiresNoMagic",
      "ByronGenesisFile": "mainnet-byron-genesis.json",
      "ByronGenesisHash": "5f20df933584822601f9e3f8c024eb5eb252fe8cefb24d1317dc3d432e940ebb",
      "ShelleyGenesisFile": "mainnet-shelley-genesis.json",
      "ShelleyGenesisHash": "1a3be38bcbb7911969283716ad7aa550250226b76a61fc51cc9a9a35d9276d81",
      "AlonzoGenesisFile": "mainnet-alonzo-genesis.json",
      "AlonzoGenesisHash": "7e94a15f55d1e82d10f09203fa1d40f8eede58fd8066542cf6566008068ed874",
      "ConwayGenesisFile": "mainnet-conway-genesis.json",
      "ConwayGenesisHash": "15a199f895e461ec0ffc6dd4e4028af28a492ab4e806d39cb674c88f7643ef62",
      "CheckpointsFile": "mainnet-checkpoints.json",
      "CheckpointsFileHash": "3e6dee5bae7acc6d870187e72674b37c929be8c66e62a552cf6a876b1af31ade"
    },
    "StorageConfig": { "LedgerDB": { "Backend": "V2InMemory" } }
  }
}
```

A section holds its configuration object directly. A path to a separate file
holding that section is rejected, and `migrate` refuses such a document rather
than produce one the parser will not read, so copy each of those files'
contents in under its section key. The genesis files and the `HermodTracing`
file are the exceptions: those stay paths, because the node reads them itself.

Other shapes still parse: a document missing any of those envelope keys, or the
legacy flat form with the component keys at the top level, is brought into the
envelope by `migrate` before it is parsed (see [Schema versioning](#schema-versioning)),
which raises a single non-fatal `MigratedToCurrentFormat` warning. See
[Warnings](#warnings).

### Schema versioning

`Version` is the configuration format version, and it is the **first component of
the package version**, which states how far the parser goes: `cardano-config-X.y.z.v`
parses every format version up to and including `X`, and writes `X`. It does that
by migrating an older document to `X` before parsing it, so there is one body
parser and one migration step per version, not one parser per version. The other
three components carry changes to the Haskell code alone, so the schemas are not
changed without bumping the first.

Each format version is published under its own `vX` git tag — `v1`, `v2`, … — cut
alongside the major release that introduces it:

```
https://raw.githubusercontent.com/IntersectMBO/cardano-config/v2/schemas/config.schema.json
```

`migrate` writes the `Version` and the `$schema` of the current format version,
so a document pinned to an earlier `vX` is moved to the current one. A document
already at the current version keeps a `$schema` it pins. A document declaring a
version *newer* than the one this `cardano-config` writes is refused, both by
`migrate` and when read, because migration never goes backwards.

To port an old config to the new format, run `cardano-config migrate` (it reads
`-` as stdin, so you can fetch and convert in one step):

```console
$ cardano-config migrate old-config.json > config.json
$ curl -sL <url-of-old-config> | cardano-config migrate - > config.json
```

It reshapes the document into the envelope as JSON: it adds `$schema` and
`Version`, carries `MinNodeVersion` through, and groups each component's keys
under its section inside `Configuration`. It also brings field names up to date:
the parser rejects the old names, so `migrate` rewrites the ones that were
renamed (`hardLimit`/`softLimit`/`delay` → `HardLimit`/`SoftLimit`/`Delay`,
the `Rpc*` keys → `Grpc*` (`EnableRpc` → `EnableGrpc`, `RpcSocketPath` →
`GrpcSocketPath`, `RpcListenAddress`/`RpcListenPort` and the `RpcTls*` trio
likewise), `TargetNumberOf*` →
`DeadlineTargetNumberOf*`) and drops the ones that were removed
(`PBftSignatureThreshold`, `LastKnownBlockVersion-Major`/`-Minor`/`-Alt`, now
supplied by consensus defaults; the vestigial `Protocol`; and
`MaxKnownMajorProtocolVersion`, a dead key the node never read). Apart from that
it preserves the values as written and does not fill in defaults or read
genesis files; follow it with `resolve` to check the result.

A genuinely unrecognised key (a typo, say) is **kept** rather than silently
dropped, so nothing is lost - but it remains unrecognised and so still surfaces
as an `UnrecognisedKeys` warning on the next parse. Remove it by hand if you want
a warning-free config.

(To port by hand instead: group the component keys under their sections inside
`Configuration` and add the `Version` / `MinNodeVersion` envelope. `cardano-config
schema` documents the recommended form; `--legacy-flat` documents the flat
form.)

## Defaults and layering

Every component ships a **default file** under [`defaults/`](defaults/), with the
network overlays under [`variants/`](variants/) and the `NetworkConfig` role
overlays under [`defaults/NetworkConfig/`](defaults/NetworkConfig/). The files
under `variants/` are templates to copy from: a configuration cannot point at
one, so paste the contents of `variants/ProtocolConfig/mainnet.json` under your
`ProtocolConfig` key. For each component the layering, from lowest to highest
precedence, is:

1. the package's base default (`defaults/<Component>.json`), always applied;
2. for the `Network` component only, a **role layer** chosen automatically from
   credential presence: the block-producer or relay variant
   (`defaults/NetworkConfig/{blockproducer,relay}.json`)
   fills the deadline peer targets and `PeerSharing` when the configuration leaves
   them unset (so it sits *below* the file value);
3. the component's inline object in the configuration file;
4. the matching CLI flag, where one exists.

`cardano-config` is the *origin* of these default files, but each is ultimately
owned by the layer that implements the component (networking, consensus, ...); a
CI check keeps the copies here aligned with upstream.

## Warnings

Parsing and resolution return non-fatal `ConfigWarning`s alongside the
configuration, rather than printing them: the caller decides whether to print
them, log them through its own tracer or treat them as fatal.
`renderConfigWarning` gives the one-line rendering the `cardano-config`
executable prints to stderr, prefixed with `Warning: `.

`parseConfigurationFiles` raises:

| Warning | Raised when |
|---------|-------------|
| `OutdatedFormatVersion declared current` | The document is at an older format version, so `migrate` upgraded it in memory. A document with no `Version` key is version 1. Run `cardano-config migrate` to update the file. |
| `MigratedToCurrentFormat` | The document is at the current version, but `migrate` still changed it before parsing, because it was not in the envelope, or used a pre-rename field name, or carried an obsolete key. An outdated version reports the warning above instead of this one. |
| `RenamedKeyCollision old new` | Both the old and the current name of a renamed field are present at the same level. The current name wins; the other value is dropped. |
| `EnvelopeKeyCollision key` | A key appears both as a top-level sibling of `Configuration` and inside it. The one inside `Configuration` wins. |
| `UnrecognisedKeys keys` | Keys at the `Configuration` level that no parser recognises: a typo, or a key of some component this library does not know. They are ignored. A key that *is* a component property is not one of these: `migrate` groups it under the section that owns it. |
| `ExperimentalGenesisIgnored file` | A `DijkstraGenesisFile` is named while `ExperimentalHardForksEnabled` is off, so the file is ignored - neither read nor hash-checked. |

`resolveConfiguration` adds:

| Warning | Raised when |
|---------|-------------|
| `ConsistencyWarning description` | A consistency check of warning severity did not hold on the resolved configuration (e.g. a Mithril snapshot policy under the `V2LSM` backend with no `LSMExportPath`). The configuration is still accepted. See `ConfigCheck`. |

Only keys at the `Configuration` level are checked against the recognised set;
an unknown key *inside* a component section is ignored silently, with no
warning.

## Cookbook: I want to ...

The JSON snippets below use the recommended envelope form. Some show only the
section under discussion: a configuration you can pass to `--config` also needs
a `ProtocolConfig` naming the four genesis files, as the first one does.

### ... define a config for running a relay node on mainnet with the default configuration

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/v2/schemas/config.schema.json",
  "Version": 2,
  "MinNodeVersion": "11.2",
  "Configuration": {
    "ProtocolConfig": {
      "RequiresNetworkMagic": "RequiresNoMagic",
      "ByronGenesisFile": "mainnet-byron-genesis.json",
      "ByronGenesisHash": "5f20df933584822601f9e3f8c024eb5eb252fe8cefb24d1317dc3d432e940ebb",
      "ShelleyGenesisFile": "mainnet-shelley-genesis.json",
      "ShelleyGenesisHash": "1a3be38bcbb7911969283716ad7aa550250226b76a61fc51cc9a9a35d9276d81",
      "AlonzoGenesisFile": "mainnet-alonzo-genesis.json",
      "AlonzoGenesisHash": "7e94a15f55d1e82d10f09203fa1d40f8eede58fd8066542cf6566008068ed874",
      "ConwayGenesisFile": "mainnet-conway-genesis.json",
      "ConwayGenesisHash": "15a199f895e461ec0ffc6dd4e4028af28a492ab4e806d39cb674c88f7643ef62",
      "CheckpointsFile": "mainnet-checkpoints.json",
      "CheckpointsFileHash": "3e6dee5bae7acc6d870187e72674b37c929be8c66e62a552cf6a876b1af31ade"
    }
  }
}
```

That `ProtocolConfig` object is the contents of
[`variants/ProtocolConfig/mainnet.json`](variants/ProtocolConfig/mainnet.json),
minus its `$schema` line. The other networks have their own file to copy from.

### ... override options in a component

Give the section the keys you want set, and the component's base default (and,
for `NetworkConfig`, the credential-derived role layer) fills the rest:

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/v2/schemas/config.schema.json",
  "Version": 2,
  "MinNodeVersion": "11.2",
  "Configuration": {
    "NetworkConfig": { "DeadlineTargetNumberOfRootPeers": 100 }
  }
}
```

### ... serve the gRPC endpoint over TCP, with or without TLS

The gRPC server listens on exactly one endpoint. By default that is a unix
socket - `GrpcSocketPath`, or, absent one, `rpc.sock` beside the node socket.
Setting `GrpcListenPort` instead makes it listen over HTTP/2 on TCP, and adding
a certificate and its private key makes that HTTP/2 over TLS:

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/v2/schemas/config.schema.json",
  "Version": 2,
  "MinNodeVersion": "11.2",
  "Configuration": {
    "LocalConnectionsConfig": {
      "EnableGrpc": true,
      "GrpcListenAddress": "0.0.0.0",
      "GrpcListenPort": 3001,
      "GrpcTlsCertificateFile": "tls/server.pem",
      "GrpcTlsPrivateKeyFile": "tls/server.key",
      "GrpcTlsChainCertificateFiles": ["tls/intermediate.pem"]
    }
  }
}
```

`GrpcListenAddress` is optional and defaults to `127.0.0.1`, so a port alone
keeps the endpoint on loopback; the chain certificates are optional too. The
combinations that describe no single endpoint are rejected as the file is
parsed: `GrpcSocketPath` alongside any of the TCP keys, an address or a TLS
credential without a port, or a certificate without its private key (or the
reverse).

The same on the command line, where `--grpc-socket-path` and
`--grpc-listen-port` are likewise alternatives:

```console
$ cardano-node run --grpc-enable --grpc-listen-address 0.0.0.0 --grpc-listen-port 3001 \
    --grpc-tls-certificate tls/server.pem --grpc-tls-private-key tls/server.key \
    --grpc-tls-chain-certificate tls/intermediate.pem ...
```

A command-line endpoint replaces the file's endpoint whole, rather than merging
into it: the two describe one choice, not a set of independent settings.

### ... see what my configuration resolves to, with defaults

```console
$ cardano-config resolve --config <your-config.json> --<other node CLI options>
ConsensusConfig:
  ConsensusMode: PraosMode
LocalConnectionsConfig:
  EnableGrpc: false
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

This checks the structure and the cross-field rules a single file can state (see
[Warnings](#warnings) for what the parser adds), section by section inside
`Configuration`. It does not check genesis
hashes, nor the rules that span the file, the command line and the defaults -
"enabling gRPC needs somewhere to listen" is satisfied by a `--socket-path` the
file never mentions - so `resolve` is still the final check.

A legacy document is expected to *fail* validation: it still parses, because
`migrate` rewrites it first, but the schema documents the current form alone.

CI runs this over a matrix of documents that must validate and documents that
must not (`test/schema-cases/`, driven by `scripts/check-schemas.sh`), so the
schemas stay in step with what the parser accepts.

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
`cardano-node`, so existing operator scripts keep working. You can inspect the
parsed options with `cabal run cardano-config -- resolve --help`.

## Tracing options are owned by `trace-dispatcher`

Tracing is owned by the node's tracing system (hermod / `trace-dispatcher`),
given under a single top-level `HermodTracing` key whose value is **either** a
path to a separate file holding the tracing configuration **or** that
configuration object inline. This library does not define or validate the shape
of that object — the authoritative schema lives in
[`hermod-tracing`](https://github.com/IntersectMBO/hermod-tracing), so the
configuration schema describes `HermodTracing` only as "a path or a JSON
object".

Instead, the parser hands the `HermodTracing` value to `trace-dispatcher`'s own
parser (`readConfiguration`), which resolves it into a `TraceConfig`: a file
reference is read via `FromFile` (after resolving the path to its canonical
location), an inline object via `FromJSONObject`.

The resolved `TraceConfig` is carried through to the final `NodeConfiguration`
(as `tracingConfiguration :: Maybe TraceConfig`), so a consumer of the library
gets the tracing configuration already parsed, and `cardano-config resolve`
emits it back under the `HermodTracing` key (as an inline object). It is
`Nothing`/absent when the configuration has no `HermodTracing` key.

## Mandatory keys

Only **eight** keys are mandatory (no default; parsing fails if absent):
- `ByronGenesisFile` + `ByronGenesisHash`
- `ShelleyGenesisFile` + `ShelleyGenesisHash`
- `AlonzoGenesisFile` + `AlonzoGenesisHash`
- `ConwayGenesisFile` + `ConwayGenesisHash`

These are network-specific, so they are deliberately not in the base defaults;
write them into `ProtocolConfig` yourself, or copy them from
`variants/ProtocolConfig/<network>.json`.

## Genesis initial-data injection

A test network's genesis can hand the ledger its initial funds, stake pools,
stake credentials, delegations and DReps either inline (the legacy
`initialFunds`, `staking`, `delegs` and `initialDReps` fields) or under the
genesis `extraConfig` key, which can point at a separate JSON file that
`cardano-ledger` streams and hash-checks while building the initial ledger
state, rather than decoding it into the genesis value:

```json
"extraConfig": {
  "initialFunds": { "file": ["initial-funds.json"], "hash": "<blake2b-256 hex>" }
}
```

The `file` is *not* a filesystem path: it is an `FsPath`, a list of path
segments the ledger resolves against a `HasFS` **the consumer supplies**. This
library fixes that filesystem to the directory holding the Shelley genesis file
(matching `cardano-node`), records it on the parsed configuration as
`genesisInjectionRoot`, and builds it with
`nodeConfigurationInjectionFS :: NodeConfiguration -> SomeHasFS IO` — hand that
to `protocolInfoCardano`. Note that this is the *genesis* directory, which is
not in general the directory the configuration file lives in.

Three things the ledger would otherwise report by throwing while it constructs
the initial ledger state are checked while the configuration is read, against
the genesis key at fault: a field may take its data from the legacy form or from
`extraConfig`, never both; none of it is allowed on a mainnet genesis; and a
referenced injection file must exist. The files' *hashes* are left to the
ledger, which verifies them as it streams each file — re-hashing here would mean
reading a potentially very large file twice.

See `Cardano.Configuration.Genesis.Injection`.

## Notes on networks

Due to the nature of each network, some features are enabled in ones and not in
others:

|             |Mainnet|Preprod|Preview|
|-------------|-------|-------|-------|
|Checkpoints  |Yes    |No     |Yes    |
|Test*HardFork|No     |No     |Yes    |
