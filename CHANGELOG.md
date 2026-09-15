# Revision history for cardano-config

## Unreleased

### Breaking changes

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

### Changed

* The `ExperimentalHardForksEnabled` description in the JSON schemas now states
  that a `DijkstraGenesisFile` and `DijkstraGenesisHash` must accompany it. This
  is an annotation only: *what validates* is unchanged, since the schemas are
  frozen per format version and `v1` is cut, so the schema still describes
  `DijkstraGenesisFile` as optional while resolution insists on it. Expressing
  the requirement as a JSON Schema `if`/`then` needs a new format version.

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
