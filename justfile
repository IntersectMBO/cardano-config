# Developer tasks for cardano-config.
#
# The CUE front-end lives in cue/; ajv and the resolve check are repo-level, so
# the whole config flow is driven from here. Run recipes from the repo root.
# Per-file recipes take a path relative to cue/ (a leading `cue/` is stripped, so
# `just vet examples/x.cue` and `just vet cue/examples/x.cue` both work).
# CUE/ajv binaries can be overridden, e.g. `CUE=~/go/bin/cue just vet ...`.

cue := env('CUE', 'cue')
ajv := env('AJV', 'ajv')

# Component schemas imported as #Definitions.
schemas := "StorageConfig ConsensusConfig ProtocolConfig NetworkConfig LocalConnectionsConfig TestingConfig MempoolConfig"

# Show the recipe list.
default:
    @just --list

# Regenerate the committed generated CUE from schemas/ and variants/.
regen:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}/cue"
    # Component definitions from the published JSON Schemas.
    for c in {{ schemas }}; do
      echo "import schema $c"
      {{ cue }} import jsonschema -p schema -l "#$c:" ../schemas/$c.schema.json -o schema/gen_$c.cue -f
    done
    # Network/role variant data, as open values for presets.cue. Paths are
    # repo-root-relative: the per-network overlays live under variants/, but the
    # NetworkConfig role overlays live under defaults/NetworkConfig/.
    while read -r name path; do
      [ -z "$name" ] && continue
      echo "import variant $name"
      {{ cue }} import "../$path" -p schema -l "$name:" -o "schema/gen_var_$name.cue" -f
    done <<'VARIANTS'
    protocolMainnet variants/ProtocolConfig/mainnet.json
    protocolPreview variants/ProtocolConfig/preview.json
    protocolPreprod variants/ProtocolConfig/preprod.json
    consensusPreview variants/ConsensusConfig/preview.json
    consensusPreprod variants/ConsensusConfig/preprod.json
    storagePreview variants/StorageConfig/preview.json
    storagePreprod variants/StorageConfig/preprod.json
    testingPreview variants/TestingConfig/preview.json
    networkRelay defaults/NetworkConfig/relay.json
    networkBlockproducer defaults/NetworkConfig/blockproducer.json
    VARIANTS

# Type-check one config/example (structure + hard rules).
vet FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}/cue"
    f="{{ FILE }}"; f="${f#cue/}"
    {{ cue }} vet "$f" -c

# Print non-fatal advisories (warnings) for one config.
lint FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    # Exits 0 with warnings; exits 1 only on a warnings-eval error (a bug in
    # #warnings, or a malformed config).
    cd "{{ justfile_directory() }}/cue"
    f="{{ FILE }}"; f="${f#cue/}"; name=$(basename "$f" .cue)
    helper=$(mktemp --suffix=.cue); err=$(mktemp)
    trap 'rm -f "$helper" "$err"' EXIT
    printf 'package main\nimport "github.com/intersectmbo/cardano-config/cue/schema"\nwarnings: (schema.#warnings & {in: node}).out\n' > "$helper"
    if out=$({{ cue }} export "$f" "$helper" -e warnings --out json 2>"$err"); then
      printf '%s' "$out" | python3 -c 'import json,sys; ws=json.loads(sys.stdin.read() or "[]"); n=sys.argv[1]; print(f"{n}: ok") if not ws else [print(f"{n}: warning: {w}") for w in ws]' "$name"
    else
      echo "$name: ERROR evaluating warnings:" >&2; sed 's/^/  /' "$err" >&2; exit 1
    fi

# Emit a single fully-inlined out/<name>.json for one config.
export FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}/cue"
    f="{{ FILE }}"; f="${f#cue/}"; name=$(basename "$f" .cue)
    mkdir -p ../out
    {{ cue }} export "$f" -e node --out json > "../out/$name.json"
    echo "wrote out/$name.json"

# Validate one config against the published config.schema.json (exports it first).
ajv FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"
    just export "{{ FILE }}" >/dev/null
    f="{{ FILE }}"; f="${f#cue/}"; name=$(basename "$f" .cue)
    # ("unknown format path" is ajv noting a non-standard format it ignores.)
    {{ ajv }} validate --spec=draft7 --strict=false -s schemas/config.schema.json -d "out/$name.json" \
      2> >(grep -v 'unknown format "path"' >&2)
    echo "$name: schema-valid"

# Fully check one config: vet, then schema-validate, then lint.
check FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    just vet "{{ FILE }}"
    just ajv "{{ FILE }}"
    just lint "{{ FILE }}"

# Resolve an exported JSON through the library (genesis files must be reachable from its dir).
resolve config:
    cabal run -v0 cardano-config -- resolve --config {{ config }}

# Remove build output.
clean:
    rm -rf {{ justfile_directory() }}/out
