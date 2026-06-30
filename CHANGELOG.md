# Revision history for cardano-config

## 0.1.0.0 -- YYYY-mm-dd

* First version. Released on an unsuspecting world.
* CLI option parser (`parseCliArgs`), JSON/YAML file parsing
  (`parseConfigurationFiles`) and resolution (`resolveConfiguration`) for the
  `cardano-node` configuration, with an `autodocodec`-derived JSON Schema.
* The public API is the single `Cardano.Configuration` module, which re-exports
  the datatypes, parsers, resolution and warnings a consumer needs. The
  implementation lives in a private `internal` sublibrary (used by this package's
  own executable and test-suite) and is not importable by downstream packages.
* `cardano-config` executable with two subcommands:
  * `cardano-config schema` dumps the `autodocodec`-derived JSON Schema (the
    whole configuration or a single component). The schemas declare a `type` for
    every scalar field (string enumerations use `enum`), flag filesystem paths
    with `"format": "path"`, and carry `title`/`$id` so documentation generators
    (e.g. `jsonschema2md`) render names rather than `Untitled`/`undefined`. Each
    key's `default` is filled in from the `defaults/` files (the single source of
    truth for defaults), so the documented default matches the applied one. The
    default whole-configuration schema describes the split-file form (plus the
    version envelope); `--legacy-one-file` dumps the legacy single-file form.
  * `cardano-config resolve` resolves a configuration (defaults + file + CLI
    flags) and prints the complete result as YAML, using the documented
    configuration keys. With `--with-geneses` it also embeds the decoded genesis
    value of every era (the files read and hash-checked at parse time); by
    default only their path and hash appear under `ProtocolConfig`.
* Configuration sources are layered with a deep merge: an always-applied
  per-component default (`defaults/`), then the configuration file (an inline
  value or a sub-file path), then CLI flags.
* The per-component section keys are suffixed `Config` (`ProtocolConfig`,
  `ConsensusConfig`, …) to avoid clashing with the node's vestigial top-level
  `Protocol` scalar (only ever `"Cardano"`), which this library does not parse
  (documented alongside `MaxKnownMajorProtocolVersion`).
* Optional `{ Version, Configuration }` envelope for forward-compatibility.
* Structured parse errors (`ConfigurationParsingError`) and resolution-time
  cross-field checks (`ConfigCheck` / `ConfigResolutionError`).
* `parseConfigurationFiles` returns the parsed configuration together with a list
  of `ConfigWarning`s rather than printing or failing on them itself, so each
  consumer chooses how to surface them (`renderConfigWarning` gives the default
  text). The warnings are: unrecognised top-level keys (`UnrecognisedKeys`,
  typos, ignored); keys shadowed by a component supplied as its own section
  (`ShadowedKeys`, ignored — the section wins); and use of the legacy single-file
  form (`LegacySingleFileFormat`).
* The split-file and legacy single-file schemas are kept separate, so neither
  offers both placements for a component; mixing the forms is caught at parse
  time (the shadowed-keys warning) rather than by a JSON Schema validator.
* `resolveConfiguration` derives the networking role from credential presence: a
  node given block-forging credentials uses the block-producer deadline
  peer-selection targets and disables `PeerSharing`; a node without uses the
  relay targets and enables it. An explicit file value for any of those fields
  still wins. (Matches the node's former `defaultDeadlineTargets` / role
  `PeerSharing` derivation.)
* The three mempool timeouts (`MempoolTimeoutSoft`/`Hard`/`Capacity`) are
  resolved all-or-nothing: set all three or none. All-unset takes the coupled
  default of `(1, 1.5, 5)` seconds; a partial set is a resolution error.
* The snapshot policy (`LedgerDB.Snapshots`) is resolved to a concrete set of
  options: the named `"Mithril"` policy expands to its fixed values, and an
  options object that sets only some fields inherits the rest from Mithril, so a
  resolved configuration always has every snapshot option set. The values are
  exposed as `mithrilSnapshotOptions` / `resolveSnapshotPolicy` so non-consensus
  consumers need not re-derive them. The snapshot policy is resolved after the
  consistency checks, so the "Mithril under V2LSM requires an LSMExportPath"
  check still sees the requested policy. Under the `V2LSM` backend,
  `LSMDatabasePath` defaults to `lsm` when unset.
