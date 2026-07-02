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

A configuration is a single JSON/YAML object. The recommended form is the
**Version1 envelope**: `$schema` (the URL of the schema the file follows),
`Version` and `MinNodeVersion` at the top level, with the components grouped
under `Configuration`, each given inline or as a path to a split sub-file:

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/config.schema.json",
  "Version": 1,
  "MinNodeVersion": "11.2",
  "Configuration": {
    "ProtocolConfig": "variants/ProtocolConfig/mainnet.json",
    "StorageConfig": { "LedgerDB": { "Backend": "V2InMemory" } }
  }
}
```

Other shapes still parse, but raise a non-fatal warning: a document missing any
of those envelope keys (`NotVersion1Envelope`) or the legacy flat form with
component keys at the top level (`LegacySingleFileFormat`). See
[Warnings](#warnings).

A component split out into its own sub-file may declare its own `$schema`
pointing to that component's schema (e.g. a `StorageConfig` sub-file uses `schemas/StorageConfig.schema.json`),
so editors and validators pick up the right schema for the sub-file. The key is
an annotation: the parser accepts and ignores it.

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
`EnableRpc`/`RpcSocketPath` → `EnableGrpc`/`GrpcSocketPath`, `TargetNumberOf*` →
`DeadlineTargetNumberOf*`) and drops the ones that were removed
(`PBftSignatureThreshold`, `LastKnownBlockVersion-Major`/`-Minor`/`-Alt`, now
supplied by consensus defaults). Apart from that it preserves the values as
written and does not fill in defaults, inline referenced sub-files, or read
genesis files; follow it with `resolve` to check the result.

Unrecognised keys (the vestigial `MaxKnownMajorProtocolVersion`, a stray
`Protocol`, or a typo) are **kept** rather than silently dropped, so nothing is
lost - but they remain unrecognised and so still surface as an
`UnrecognisedKeys` warning on the next parse. Remove them by hand if you want a
warning-free config.

(To port by hand instead: group the component keys under their sections inside
`Configuration` and add the `Version` / `MinNodeVersion` envelope. `cardano-config
schema` documents the recommended form; `--legacy-one-file` documents the flat
form.)

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

`cardano-config` is the *origin* of these default files, but each is ultimately
owned by the layer that implements the component (networking, consensus, ...); a
CI check keeps the copies here aligned with upstream.

## Cookbook: I want to ...

The JSON snippets below use the recommended envelope form; the complete ones can
be passed straight to `--config` (a few show just the relevant fragment).

### ... define a config for running a relay node on mainnet with the default configuration

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/config.schema.json",
  "Version": 1,
  "MinNodeVersion": "11.2",
  "Configuration": {
    "ProtocolConfig": "variants/ProtocolConfig/mainnet.json"
  }
}
```

### ... override options in a component

A component is a single source: an inline object, or a string path to a sub-file.
Give it the keys you want set, and the component's base default (and, for
`NetworkConfig`, the credential-derived role layer) fills the rest:

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/config.schema.json",
  "Version": 1,
  "MinNodeVersion": "11.2",
  "Configuration": {
    "ProtocolConfig": "variants/ProtocolConfig/mainnet.json",
    "NetworkConfig": { "TargetNumberOfRootPeers": 100 }
  }
}
```

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
supply them directly or by referencing a `variants/ProtocolConfig/<network>.json`
file.

## Notes on networks

Due to the nature of each network, some features are enabled in ones and not in
others:

|             |Mainnet|Preprod|Preview|
|-------------|-------|-------|-------|
|Checkpoints  |Yes    |No     |Yes    |
|Test*HardFork|No     |No     |Yes    |
