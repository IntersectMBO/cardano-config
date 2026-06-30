#!/usr/bin/env bash
# CI checks for the CUE front-end (the per-file `just` recipes operate on one
# file; this runs them across everything, plus the generated-file drift gate).
#
# Run from anywhere. Honours $CUE / $AJV like the justfile.
set -euo pipefail

cd "$(dirname "$0")/.."

cue=${CUE:-cue}

# 1. The committed generated CUE must match schemas/ + variants/.
just regen
if ! git diff --exit-code -- cue/schema/gen_*.cue; then
  echo "cue/schema/gen_*.cue is stale: run 'just regen' and commit" >&2
  exit 1
fi

# 2. The schema package itself type-checks.
(cd cue && "$cue" vet ./schema)

# 3. Every config and example vets, schema-validates, and lints.
shopt -s nullglob
for f in cue/examples/*.cue cue/configs/*.cue; do
  echo "== $f =="
  just vet "$f"
  just ajv "$f"
  just lint "$f"
done

echo "cue-ci: OK"
