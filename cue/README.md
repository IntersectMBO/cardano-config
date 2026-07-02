# CUE front-end for cardano-config

Author `cardano-node` configurations as typed CUE. `cue vet` checks structure and
the cross-field rules the JSON Schema can't express, `cue export` emits JSON, and
the `cardano-config` executable resolves it. CUE catches mistakes early; the
**library remains the final authority** - it re-parses the JSON, fills defaults,
and verifies genesis hashes (which CUE and ajv cannot).

## Recommended format

The **Version 1 envelope**: `$schema` (the schema the file follows), `Version`
and `MinNodeVersion` at the top level, with components grouped under
`Configuration` per section (each given inline, or as a path to a split
sub-file). Anything else draws a non-fatal warning (a missing envelope key, or
the legacy flat form).

```json
{
  "$schema": "https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/config.schema.json",
  "Version": 1,
  "MinNodeVersion": "10.5.0",
  "Configuration": {
    "ProtocolConfig": { "...": "..." },
    "StorageConfig":  "storage.json"
  }
}
```

## Cookbook

All `just` recipes run from the repo root. The per-file recipes - `vet`, `lint`,
`export`, `ajv` and `check` - each **take a config path** (relative to `cue/`),
e.g. `just vet configs/my-node.cue`; they act on that one file, not on every
config. (`regen` takes no argument; `resolve` takes an exported JSON.) Override
the binaries with env vars if needed, e.g.
`CUE=~/go/bin/cue just vet configs/my-node.cue`.

### 1. Install

```sh
cabal install cardano-config:exe:cardano-config   # the resolver/validator
go install cuelang.org/go/cmd/cue@v0.17.0          # CUE (pin: gen files use 0.17)
sudo apt-get install -y just                       # task runner
npm install -g ajv-cli                             # JSON Schema validator
```

### 2. Author a config

Copy an example from `examples/` and edit. `#Node` is the envelope: `$schema`
and `Version` default and `Configuration` is required (all emitted
automatically); set `MinNodeVersion`. Unify a network preset (`mainnet`,
`preview` or `preprod`) into `Configuration`, then write only your deviations:

```cue
// configs/my-node.cue
package main

import "github.com/intersectmbo/cardano-config/cue/schema"

node: schema.#Node & {
	MinNodeVersion: "10.5.0"
	Configuration: schema.mainnet & {
		StorageConfig: LedgerDB: {Backend: "V2LSM", LSMExportPath: "lsm-export"}
	}
}
```

### 3. Check, lint, export (one file)

Each recipe takes a single config path (relative to `cue/`; a leading `cue/` is
stripped, so both forms work):

```sh
just vet    configs/my-node.cue   # structure + hard rules (gRPC socket; mempool timeouts all-or-nothing)
just lint   configs/my-node.cue   # advisories: missing MinNodeVersion, V2LSM+Mithril without LSMExportPath, ...
just export configs/my-node.cue   # write out/my-node.json (a single fully-inlined envelope)
just check  configs/my-node.cue   # vet + schema-validate (ajv) + lint, in one go
```

Raw `cue` equivalents, run from inside `cue/` (the module root, needed for
imports to resolve):

```sh
cd cue
cue vet    configs/my-node.cue -c                                   # = just vet
cue export configs/my-node.cue -e node --out json                   # = just export
```

`just lint` has no one-liner equivalent: it unifies the config's `node` with
`schema.#warnings` and reads `.out`, which an inline `-e` can't reach (imports are
file-scoped), so the recipe injects a tiny helper file to do it.

### 4. Validate the JSON against the published schema (ajv)

```sh
just ajv configs/my-node.cue   # exports it, then validates against schemas/config.schema.json
```

ajv checks structure only - not genesis hashes or the cross-field rules. A clean
ajv run does not guarantee the node will accept the config; only `resolve` does.

Standalone (outside the repo, on an already-exported JSON), point ajv at the
published schema - the committed schemas declare it as their `$id`:

```sh
curl -sO https://raw.githubusercontent.com/IntersectMBO/cardano-config/main/schemas/config.schema.json
ajv validate --spec=draft7 --strict=false -s config.schema.json -d my-node.json
```

### 5. Resolve and inspect

```sh
cardano-config resolve --config my-node.json                 # fully-resolved YAML
cardano-config resolve --config my-node.json --with-geneses  # also embed era genesis values
```

The genesis files referenced by the config must be reachable from its directory.
In-repo shortcut: `just resolve out/my-node.json`.

## Maintaining

`schema/gen_<Component>.cue` are generated from `../schemas/*.schema.json` and
`schema/gen_var_*.cue` from `../variants/`; never edit them by hand. After the
schemas or variants change, run `just regen` (with **CUE 0.17.0** - importer
output varies by version) and commit.

`scripts/cue-ci.sh` is the CI gate: it fails on stale generated files, then runs
`just vet` / `just ajv` / `just lint` over every config and example. Run it
locally to check everything at once (the per-file `just` recipes check one file).
