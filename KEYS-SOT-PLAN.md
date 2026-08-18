# Plan: make cardano-config the single source of truth for Cardano key & credential parsing

**Audience:** an agent or engineer starting work in the `cardano-config` repo with no prior context.
**Status:** plan only — no code written yet. Stages 1–3 are actionable; stage 4 needs human buy-in
first (see [Open decisions](#12-open-decisions)).

---

## 1. Goal

Move cardano-api's key decoding layer into a new component of this repo so that **one**
implementation parses Cardano key material, and `cardano-api`, `cardano-cli` (indirectly),
`cardano-node` and `ouroboros-consensus` all consume it.

Two things motivate this:

1. **Immediate:** `ouroboros-consensus` carries a **2022 fork of cardano-api's key layer** (~3,800
   lines under `ouroboros-consensus-cardano/src/unstable-cardano-tools/Cardano/{Api,Node}/`) purely
   so its `db-synthesizer` tool can read forging credentials. That fork is currently being deleted
   (branch `js/eject-db-synth2`), which also deletes the `db-synthesizer` executable. If this repo
   can parse credentials, `db-synthesizer` comes back with ~400 lines of consensus glue and no
   vendored code.
2. **Strategic:** the fork exists because `ouroboros-consensus` *cannot* depend on `cardano-api`
   (§2). Any repo in that position has to duplicate. Putting the decoding layer here — below both
   api and consensus — removes the reason to fork.

---

## 2. The non-negotiable constraint

`cardano-api`'s library depends on consensus (`cardano-api/cardano-api.cabal:180`):

```
ouroboros-consensus:{cardano, diffusion, ouroboros-consensus, protocol} ^>=4.0,
```

And `ouroboros-consensus` depends on this package (`ouroboros-consensus.cabal:1784,1961`, in
`library unstable-cardano-tools` and `test-suite tools-test`):

```
cardano-config ^>=1,
```

So:

- `cardano-config → cardano-api` is a **cycle**. This package must never depend on cardano-api, and
  never on ouroboros-consensus.
- `cardano-api → cardano-config` is **legal and acyclic**. This is the whole basis of the plan.

**Corollary — where the seam falls.** Everything that turns *bytes into key material* can live
here. Everything that produces a **consensus type** cannot, ever. Concretely, cardano-node's
`readLeaderCredentials :: Maybe ProtocolFilepaths -> ExceptT PraosLeaderCredentialsError IO
[ShelleyLeaderCredentials StandardCrypto]` returns a consensus type and builds
`PraosCredentialsAgent` from `Ouroboros.Consensus.Protocol.Praos.Common`. That function stays in
cardano-node. Its ~40-line tail (`mkPraosLeaderCredentials`) is all that remains there once decoding
lives here.

---

## 3. Design principles

**Minimal, and wide.**

- **Wide:** all ~26 key roles cardano-api knows about, not just the three the node forges with. The
  role catalogue is the part that must not be thinned — a partial copy is what went wrong in
  ouroboros-consensus in 2022.
- **Minimal:** types, decoding classes, and decoding functions only. No presentation, no alternative
  encodings, no IO. Ideally the keys component is **pure** — zero IO, so it cannot grow opinions
  about file permissions, platform compat, or error rendering.

**The instance rule.** Instances of *decoding* classes live with the types, here. Instances of
*presentation*, *alternative encoding*, and *integration* classes stay in cardano-api.

**Why leaving instances behind is safe.** `class (HasTypeProxy a, SerialiseAsRawBytes a) =>
SerialiseAsBech32 a` — if the class stays in cardano-api and the type moves here, then
`instance SerialiseAsBech32 (VerificationKey PaymentKey)` written in cardano-api is **not an
orphan**, because the class is local to the module's own package. No `-Worphans`, no coherence risk.
The same holds for `Error`, `Pretty`, and `SerialiseAsBech32` across the board.

**What the rule cannot buy.** The decoders are class-polymorphic:

```haskell
deserialiseFromTextEnvelope :: HasTextEnvelope a => TextEnvelope -> Either TextEnvelopeError a
```

(note: no `AsType` argument any more — pure, return-type polymorphic), with the chain
`HasTextEnvelope ⊃ SerialiseAsCBOR ⊃ HasTypeProxy` and `SerialiseAsRawBytes ⊃ HasTypeProxy`. So
`HasTypeProxy`, `SerialiseAsCBOR`, `SerialiseAsRawBytes`, `HasTextEnvelope`, `Key` **and their ~26
role instances** must be here. That is most of `Key/Internal.hs`'s bulk, and it is not boilerplate to
be avoided — it *is* the decoding function. "No instances" is therefore not literal; the rule above
is the achievable version.

**Error convention.** No `Error`/`Pretty` instances here. Define error types with `Show` plus
`renderX :: X -> Text`, mirroring this repo's existing `renderConfigWarning`. cardano-api then writes
`instance Error X where displayError = pretty . renderX`.

---

## 4. Target packaging

Create a **separate component** — do not put this in the `internal` library.

Recommended: a **sibling package** in this repo, `cardano-keys`, with namespaces `Cardano.Key.*` and
`Cardano.Serialise.*`. A public sublib (`cardano-config:keys`) also works.

- **Namespace.** `Cardano.Configuration.*` is the wrong home for a key layer, and "cardano-api's
  keys live in cardano-config" is the part most likely to stall in review. A sibling package in the
  same repo costs nothing extra in CI and makes the story obvious. Renaming is *forced* regardless:
  cardano-api cannot re-export a module name it also defines.
- **Dependency isolation (critical).** Cabal resolves dependencies per component, so a consumer of
  the keys component does **not** inherit `yaml`, `optparse-applicative`, `iproute`, `network`, or
  `trace-dispatcher ^>=2.13` from the config library. Expect the cardano-api maintainers to raise
  exactly this; the answer is that they only build the keys component.
- **Release cadence.** A separate version lets keys move without forcing every config consumer to
  re-resolve.

**Do not add a `cardano-cli → cardano-config` edge.** Of the 156 files in `cardano-cli/src` that
import cardano-api, 149 import bare `Cardano.Api`; only 3 reach for a specific module
(`Cardano.Api.Serialise.Raw`). If cardano-api re-exports the moved names unchanged, cardano-cli needs
approximately zero changes. Fewer edges, same single source of truth.

---

## 5. What moves: tiered

**Take the code from `cardano-api`.** cardano-node implements none of this machinery; it only
consumes it. Do **not** copy from ouroboros-consensus's vendored fork — it is four years stale
(`shelleyKESFile` where the node now has `shelleyKESSource` with a KES-agent variant, and ~14 key
roles missing). See §13 for the drift evidence.

Paths below are relative to `cardano-api/src/Cardano/Api/`.

### Tier 0 — lifts verbatim

| File | Lines | Note |
|---|---|---|
| `HasTypeProxy.hs` | 68 | **zero** cardano-api imports |
| `Hash.hs` | 37 | imports only `HasTypeProxy` |
| `Serialise/Cbor.hs` | 31 | imports only `HasTypeProxy` |
| `Key/Internal/Class.hs` | 110 | imports only tier-0 modules |

### Tier 1 — needs splitting (clean cuts, but cuts)

| File | Lines | Moves | Stays in cardano-api |
|---|---|---|---|
| `Serialise/Raw.hs` | 163 | `SerialiseAsRawBytes` class, `deserialiseFromRawBytes` | `Error`/`Pretty` instances for `SerialiseAsRawBytesError`, the `Parser.Text` helper, `Monad.Error` usage |
| `Serialise/SerialiseUsing.hs` | 113 | `UsingRawBytesHex` | `UsingBech32` (it pulls `Serialise/Bech32` + `Json`) |
| `Serialise/TextEnvelope/Internal.hs` | 405 | `TextEnvelope`, `TextEnvelopeType`, `TextEnvelopeDescr`, `TextEnvelopeError`, `HasTextEnvelope`, `textEnvelopeRawCBOR`, `expectTextEnvelopeOfType`, `decodeTextEnvelopeJSON`, `deserialiseFromTextEnvelope{,AnyOf,JSON,JSONAnyOf}`, `serialiseToTextEnvelope`, `serialiseTextEnvelope`, `textEnvelopeToJSON`, `FromSomeType` | `readFileTextEnvelope`, `writeFileTextEnvelope{,WithOwnerPermissions}`, `readTextEnvelopeFromFile`, `readTextEnvelopeOfTypeFromFile`, `readFileTextEnvelopeAnyOf` (these are why it imports `Cardano.Api.IO`), `Error`/`Pretty` instances, `textEnvelopeTypeInEra`, `textEnvelopeTypeToEra`, `legacyComparison` |
| `Certificate/Internal/OperationalCertificate.hs` | 199 | `OperationalCertificate`, `OperationalCertificateIssueCounter`, their `AsType` + `HasTextEnvelope` instances, `getHotKey` (≈ lines 46–108) | `issueOperationalCertificate`, `OperationalCertIssueError` (line 110+; needs `Cardano.Api.Address`, `ProtocolParameters`, `Tx.Internal.Sign`) |

The role modules move whole **minus their bech32 deriving** — 37 `SerialiseAsBech32` mentions across
them get re-homed into a new cardano-api module:

| File | Lines | Bech32 mentions to re-home |
|---|---|---|
| `Key/Internal.hs` | 2243 | 29 |
| `Key/Internal/Praos.hs` | 257 | 5 |
| `Key/Internal/Leios.hs` | 218 | 3 |
| `Byron/Internal/Key.hs` | 298 | 0 |

`Key/Internal.hs` also imports `Cardano.Api.Parser.Text` for exactly one function, `parseHexHash ::
SerialiseAsRawBytes (Hash a) => P.Parser (Hash a)` at line 2242. Leave `parseHexHash` behind in
cardano-api so `Parser/Text.hs` (68) does not have to move.

Keep `Show` and the JSON instances (`ToJSON` 8, `FromJSON` 5, `ToJSONKey` 5) **with the types**: they
derive via `UsingRawBytesHex`, `aeson` is already a dependency here, and nobody objects to `Show`.

**Do not restructure while moving.** `Key/Internal.hs` stays one module even at 2,243 lines. The
stage-4 diff in cardano-api should be as close to a pure delete as possible.

### Tier 2 — stays in cardano-api entirely

| File | Lines | Reason |
|---|---|---|
| `Error.hs` | 122 | class stays; instances for moved types are written here (non-orphan) |
| `Pretty.hs` + `Pretty/Internal/ShowOf.hs` | 127 | keeps `prettyprinter` out of this repo |
| `IO.hs` + `IO/Internal/{Base,Compat}.hs` + `Compat/{Posix,Wasm,Win32}.hs` | 476 | the keys component is pure; `File`, `FileError`, `checkVrfFilePermissions` stay |
| `Serialise/Bech32.hs` | 189 | avoids `bech32`, `bech32-th` |
| `Serialise/Cip129.hs` | 270 | bech32-dependent |
| `Serialise/DeserialiseAnyOf.hs` | 257 | CLI input formats |
| `Serialise/Json.hs` | 105 | presentation |
| `Serialise/Cbor/Canonical.hs` | 93 | tx canonicalisation |
| `Key/Internal/Mnemonic.hs` | 360 | pulls `cardano-addresses`, `basement`, BIP39 wordlists for one CLI command |
| `Key/Internal/SomeAddressVerificationKey.hs` | 195 | imports `Cardano.Api.Address` |
| `Serialise/TextEnvelope/Internal/Cddl.hs` | 360 | imports `Tx.Internal.{Serialise,Sign}`, `ShelleyBasedEra` |
| `Internal/Orphans/{Misc,Serialisation}.hs` | 830 | `Serialisation` imports `Tx.Internal.TxIn`, `Api.Ledger`, `Monad.Error`; move nothing from `Misc` unless a compile error demands it |
| `Parser/Text.hs` | 68 | see `parseHexHash` above |

### Totals

**Moves: ~4,200 lines**, of which ~3,000 is the role catalogue (the width that must be preserved).
**Stays: ~3,450 lines** plus every awkward dependency.

Compared with a bulk lift of the whole key layer (~6,000 lines), this avoids taking on
`prettyprinter`, ansi-terminal, `bech32`, `bech32-th`, `cardano-addresses`, `basement`, BIP39,
`unix`/`Win32`, and the `Cardano.Api.Ledger` / tx orphan tangle.

### Cost of minimality — be aware before starting

Tiering converts four clean file lifts into four surgeries plus ~26 per-role edits to strip bech32
deriving. Budget an extra day or two, and expect a slightly larger stage-4 diff in cardano-api (a new
module holding 37 bech32 instances rather than a pure delete).

One ergonomic consequence to accept up front: anyone importing `cardano-keys` directly gets key types
with no bech32 or `Error` instances in scope, and GHC's "No instance for `SerialiseAsBech32`" will not
hint at why. Mitigation: `Cardano.Api`'s re-export list stays complete, so no existing consumer sees
it.

---

## 6. Module map

Sign this off before moving code (§12). Producing this table, filled in and reviewed, should be the
**first deliverable** — not a byproduct.

| cardano-api source | `cardano-keys` target |
|---|---|
| `Cardano.Api.HasTypeProxy` | `Cardano.Key.HasTypeProxy` |
| `Cardano.Api.Hash` | `Cardano.Key.Hash` |
| `Cardano.Api.Key.Internal.Class` | `Cardano.Key.Class` |
| `Cardano.Api.Key.Internal` (minus bech32, `parseHexHash`) | `Cardano.Key.Shelley` |
| `Cardano.Api.Key.Internal.Praos` | `Cardano.Key.Praos` |
| `Cardano.Api.Key.Internal.Leios` | `Cardano.Key.Leios` |
| `Cardano.Api.Byron.Internal.Key` | `Cardano.Key.Byron` |
| opcert slice of `Cardano.Api.Certificate.Internal.OperationalCertificate` | `Cardano.Key.OperationalCertificate` |
| `Cardano.Api.Serialise.Cbor` | `Cardano.Serialise.Cbor` |
| `Cardano.Api.Serialise.Raw` (pure part) | `Cardano.Serialise.Raw` |
| `UsingRawBytesHex` from `Cardano.Api.Serialise.SerialiseUsing` | `Cardano.Serialise.Using` |
| `Cardano.Api.Serialise.TextEnvelope.Internal` (pure part) | `Cardano.Serialise.TextEnvelope` |

New modules needed on the cardano-api side to hold what stays: one for the 37 `SerialiseAsBech32`
instances, one for the `Error`/`Pretty` instances of moved error types.

---

## 7. Deliverable API

Agree this **before** writing code: both ouroboros-consensus's glue and cardano-node's wrap bind to
it, and two implementers left to their own devices will produce two incompatible shapes.

### 7a. `cardano-keys` — pure, no IO

Exports the classes and roles from §6, plus:

```haskell
-- Cardano.Serialise.TextEnvelope
data TextEnvelope = TextEnvelope
  { teType        :: !TextEnvelopeType
  , teDescription :: !TextEnvelopeDescr
  , teRawCBOR     :: !ByteString
  }
instance FromJSON TextEnvelope   -- {"type":…, "description":…, "cborHex":…}
instance ToJSON   TextEnvelope

deserialiseFromTextEnvelope :: HasTextEnvelope a => TextEnvelope -> Either TextEnvelopeError a
decodeTextEnvelopeJSON      :: ByteString -> Either TextEnvelopeError TextEnvelope
renderTextEnvelopeError     :: TextEnvelopeError -> Text
```

No `File`, no `FilePath`, no `IO` anywhere in this component.

### 7b. Credential reading — in the config library, on top of `cardano-keys`

This is the node-facing entry point. It hangs off the credential paths this repo **already** models
in `src/Cardano/Configuration/CliArgs.hs`:

```haskell
data KESSource = KESKeyFilePath FilePath | KESAgentSocketPath FilePath

data Credentials = Credentials
  { byronDelegationCertificate    :: StrictMaybe FilePath
  , byronSigningKey               :: StrictMaybe FilePath
  , shelleyKES                    :: StrictMaybe KESSource
  , shelleyVRFKey                 :: StrictMaybe FilePath
  , shelleyOperationalCertificate :: StrictMaybe FilePath
  , bulkCredentialsFile           :: StrictMaybe FilePath
  }
```

Proposed result type and entry point:

```haskell
readCredentials :: Credentials -> IO (Either CredentialsError DecodedCredentials)

data DecodedCredentials = DecodedCredentials
  { byronCredentials   :: Maybe ByronCredentials
  , shelleyCredentials :: [ShelleyCredentials]   -- singleton (if any) ++ bulk file entries
  }

data ByronCredentials = ByronCredentials
  { byronCertificate :: Byron.Certificate
  , byronSigningKey  :: SigningKey ByronKey
  }

data ShelleyCredentials = ShelleyCredentials
  { operationalCertificate :: OperationalCertificate
  , vrfSigningKey          :: SigningKey VrfKey
  , kesCredentials         :: KESCredentials
  , credentialsLabel       :: Text   -- provenance, for error messages
  }

data KESCredentials
  = KESCredentialsKey   (SigningKey KesKey)  -- from a file, cross-checked against the opcert
  | KESCredentialsAgent FilePath             -- socket path, passed through unchecked

renderCredentialsError :: CredentialsError -> Text
```

Consumers then map `ShelleyCredentials` to their own types — `ShelleyLeaderCredentials` with
`PraosCredentialsUnsound` or `PraosCredentialsAgent`, and `ByronLeaderCredentials` — which is the
~40-line wrap that stays in consensus and in cardano-node.

**Invariants to reproduce exactly** (spec is cardano-node, see §8c):

- all six inputs supported, including the legacy Byron XPrv signing-key format;
- opcert↔KES cross-check: `verificationKeyHash (getHotKey opCert)` must equal
  `verificationKeyHash (getVerificationKey kesSKey)`, else a mismatch error naming both files;
- all-or-none discipline for the Shelley triple — supplying some but not all is an error
  (`OCertNotSpecified` / `VRFKeyNotSpecified` / `KESKeyNotSpecified` in the node's vocabulary);
- singleton and bulk credentials are **concatenated**, not alternatives;
- `credentialsLabel` preserves the node's per-entry provenance for bulk files
  (`<file> <> "." <> show ix <> "cert" | "vrf" | "kes"`);
- **preserve the known gap**: with a KES *agent*, the node does not cross-check the opcert against
  the agent's key (`TODO: minor yikes` at `cardano-node/src/Cardano/Node/Protocol/Shelley.hs:198`).
  Do not silently fix this; if it should be fixed, that is a separate decision.

---

## 8. What comes from cardano-node

### 8a. The bulk credentials format — one genuine piece

`readLeaderCredentialsBulk`, the `ShelleyCredentials` record, and the
`[(TextEnvelope, TextEnvelope, TextEnvelope)]` JSON shape, in
`cardano-node/src/Cardano/Node/Protocol/Shelley.hs:240+`.

`grep -rn bulk cardano-api/src --include='*.hs'` returns **nothing** — cardano-api has no knowledge
of this format. It is node-only knowledge, so if this package is to own credential *files* rather
than just key blobs, that parser comes from cardano-node.

`ProtocolFilepaths` (`cardano-node/src/Cardano/Node/Types.hs:183`) does **not** move — it is already
superseded by `Credentials`/`KESSource` here, which are *ahead* of the consensus fork in modelling
`KESAgentSocketPath`.

### 8b. One duplicate, resolve in cardano-api's favour

`VRFPrivateKeyFilePermissionError` exists in both repos: cardano-api
`IO/Internal/Compat/Posix.hs:11` and `Compat/Wasm.hs:41` (real implementation, per platform), and
cardano-node `src/Cardano/Node/Types.hs:518` (its own `data` declaration plus a renderer). Keep
cardano-api's — it stays in tier 2, and cardano-node's copy becomes a re-export and is then deleted.

### 8c. Reference only — moves nowhere

`readLeaderCredentials`, `readLeaderCredentialsSingleton`, `opCertKesKeyCheck` in
`cardano-node/src/Cardano/Node/Protocol/Shelley.hs:161-232`. Consensus-typed (§2). This is the
behavioural spec for §7b.

---

## 9. Dependencies

**Needed by `cardano-keys`:** `base16-bytestring`, `cardano-binary`, `cardano-crypto` (XPrv /
`Cardano.Crypto.Wallet`), `cardano-ledger-binary`, `cardano-protocol-tpraos`, `cborg` — on top of
`aeson`, `bytestring`, `text`, `cardano-crypto-class`, `cardano-ledger-core`, which this repo already
has. No consensus, no cardano-api, no IO.

**Deliberately avoided by the tiering:** `prettyprinter`, ansi-terminal, `bech32`, `bech32-th`,
`cardano-addresses`, `basement`, BIP39, `unix`, `Win32`.

**Check:** `Key/Internal/Leios.hs` (`BlsKey`) needs `Cardano.Crypto.DSIGN.BLS12381` — confirm the
existing `cardano-crypto-class ^>=2.5` bound covers it and whether BLS sits behind a cabal flag.

---

## 10. Build and repo constraints

Read this before the first `cabal build`; several of these bite late.

- **`-Werror` everywhere.** `cabal.project` sets `program-options: ghc-options: -Werror`, and the
  `internal` library adds `-Wall -Wunused-packages`. Four thousand lines lifted from a repo with
  different flags will not be warning-clean: unused imports after each split, `-Wunused-packages` on
  a brand-new component. **Do not relax the flags to get green.**
- **GHC matrix.** `tested-with: ghc ==9.6 || ==9.8 || ==9.10 || ==9.12 || ==9.14`. The moved code
  must build on all of them.
- **`cabal.project`** has `packages: .` — a sibling package needs its own entry.
- **CI** is `.github/workflows/ci.yml`, cabal-based (no nix).
- **Formatting.** This repo's `fourmolu.yaml` differs from cardano-api's, so every moved file
  reformats. Expected — but say so in the PR description, because the diff looks alarming otherwise.
- **Index state.** `cabal.project` pins `hackage.haskell.org 2026-07-31` and CHaP `2026-07-30`; new
  dependency versions must exist at those index states or the pins move deliberately.

---

## 11. Test fixtures

**cardano-api has none to copy** — there are zero `.skey`/`.vkey`/KES/VRF/opcert files under
`cardano-api/test`. Do **not** hand-roll CBOR fixtures: a fixture that round-trips through your own
decoder proves nothing and goes green while doing it.

Sources that do exist:

- `cardano-cli/cardano-cli/test/cardano-cli-golden/files/input/shelley/node-pool/` (e.g. `vrf.vkey`)
  and `.../files/input/` more broadly (`delegate1.skey`, `genesis1.{skey,vkey}`, `drep.vkey`,
  `conway/cold1-cc.skey`, …).
- `cardano-cli/cardano-cli/test/cardano-cli-golden/Test/Golden/Shelley/TextEnvelope/Keys/{KESKeys,VRFKeys}.hs`
  and `.../Node/KeyGen{Kes,Vrf}.hs` — these *generate* keys, so they show the exact envelope types
  and descriptions to expect.
- Or generate fresh ones with a built `cardano-cli` (`node key-gen-KES`, `node key-gen-VRF`,
  `node issue-op-cert`) and commit them as fixtures.

Minimum bar for stage 1: decode a real opcert + KES key + VRF key triple, assert the opcert↔KES
cross-check both passes and fails correctly, decode a real bulk-creds file with ≥2 entries, and
round-trip every role's envelope type string. Bring across
`cardano-api/test/cardano-api-test/Test/Cardano/Api/KeysByron.hs` and the golden error directory
`files/errors/Cardano.Api.Serialise.TextEnvelope.Internal.TextEnvelopeError/` (it moves with its
error type).

---

## 12. Staging

Each stage is independently shippable. **Stage 2 is what unblocks db-synthesizer, and it does not
wait for cardano-api.**

1. **`cardano-keys` + credential reader** — tiers 0 and 1 for the credential path (envelope core, raw
   bytes, KES/VRF/opcert/Byron/`StakePoolKey`), the bulk-creds parser, and §7b. Purely additive; no
   existing consumer changes. → release.
2. **ouroboros-consensus restores `db-synthesizer`** — depends on `cardano-keys`, keeps ~400 lines of
   consensus glue (`ShelleyLeaderCredentials`, `CardanoProtocolParams`) plus the restored executable
   and `DBSynthesizer/Parsers.hs`. Recoverable from that repo's history: `git show e7f2afefb^`, and
   `docs/db-synthesizer-downstream.md` on branch `js/eject-db-synth2`.
3. **Widen to the full catalogue** — the remaining roles and extended variants, DRep/committee keys,
   `Leios`/`BlsKey`, generators, golden tests. ~2–3 weeks.
4. **cardano-api PR** — delete the moved code, depend on `cardano-keys`, add the two new instance
   modules, re-export everything from `Cardano.Api` unchanged. Blast radius inside
   `cardano-api/src`: 47 modules import `HasTypeProxy`, 41 import `Pretty`, 40 import `Error`
   (54 `instance Error` declarations across 29 files), 25 import `Serialise.Raw`, 25 import
   `Serialise.TextEnvelope.Internal`. Major version bump, since internal module paths disappear.
   cardano-cli should need ~no changes (§4).
5. **cardano-node cleanup** — read credentials via this package, keeping only the ~40-line
   `mkPraosLeaderCredentials` wrap; delete its duplicate `VRFPrivateKeyFilePermissionError`. Note
   cardano-node does not depend on cardano-config *at all* yet (no hits in `cardano-node.cabal` or
   `cabal.project`), so that adoption is a prerequisite tracked separately.

Engineering effort for stages 1, 3 and 4: roughly 4–6 weeks. Calendar time is dominated by stage 4's
review and the release chain.

---

## 13. Open decisions

Needed from a human, ideally before stage 3:

1. **Does the cardano-api team accept stage 4 in principle?** Stages 1–3 are worth doing regardless —
   worst case this repo owns a key-parsing library with two consumers instead of three — but "single
   source of truth" is only *true* if stage 4 lands, and that is not this repo's call.
2. **Ongoing cost to state to them explicitly:** after stage 4, every key-layer change needs a
   release of this package before cardano-api can pick it up. cardano-api releases often (11.4.0.0 on
   2026-08-06); confirm they accept that coupling.
3. **Sibling package `cardano-keys` vs public sublib `cardano-config:keys`** (§4).
4. **Sign off the module map** (§6) and the API in §7 before code moves.
5. **Does `Mnemonic.hs` ever move?** Currently tier 2 (§5). It is the one piece where "wide" and
   "minimal" genuinely conflict.
6. **The KES-agent opcert check** (§7b, last bullet) — preserve the gap now; decide separately
   whether to close it.

---

## 14. Provenance of the numbers

Measured 2026-08-17/18 from these local checkouts. **Re-verify line numbers before relying on
them** — upstream moves.

| Repo | Path | HEAD |
|---|---|---|
| cardano-api | `../cardano-api` | `1c81d28a1` (2026-08-06, "Release cardano-api-11.4.0.0") |
| cardano-node | `../cardano-node` | `4860dd8cf` (2026-08-12, "bump ouroboros-consensus to 4.1") |
| cardano-cli | `../cardano-cli` | `75d405c19` (2026-07-22) |
| ouroboros-consensus | `../ouroboros-consensus` | `8ad4b4dfa`, branch `js/eject-db-synth2` |
| cardano-config | this repo | `9fcad64` (main), version 1.0.0.0 |

### Why the vendored fork is not a viable source

Created wholesale in `ae73f61ee` (2022-07-07, "cardano-tools: new project (squashed)") — 16 files
copied at once, all ten Shelley key roles present from the first commit, never curated afterwards.
Nothing ever imported nine of those ten roles; the copy was only touched by mechanical upkeep (import
regrouping 2022-08, ledger/base integration 2023-01, package reorgs 2023-04, `unstable-` rename
2023-08, pragma cleanup 2024-05, KES agent 2025-01).

Drift as of cardano-api 11.4.0.0: the fork has 10 Shelley roles plus `ByronKey`/`ByronKeyLegacy`;
cardano-api has 26 role and witness types, having since added `BlsKey`, `DRepKey`,
`DRepExtendedKey`, `CommitteeColdKey`, `CommitteeColdExtendedKey`, `CommitteeHotKey`,
`CommitteeHotExtendedKey`, `StakePoolExtendedKey`, `AnyStakePoolSigningKey`,
`AnyStakePoolVerificationKey`, `SomeAddressVerificationKey`, `SomeByronSigningKey`.

### Who the key catalogue is for

cardano-cli — which is why it must keep working unchanged, and why "wide" is the right call. Usage
across 34 files in `cardano-cli/src`: `StakeKey` 32, `GenesisDelegateKey` 31, `CommitteeColdKey` 31,
`GenesisKey` 30, `VrfKey` 29, `StakePoolKey` 27, `CommitteeHotKey` 22, `DRepKey` 21, `PaymentKey` 15,
`GenesisDelegateExtendedKey` 13, `KesKey` 8, `GenesisUTxOKey` 6, `StakeExtendedKey` 5,
`GenesisExtendedKey` 5, `PaymentExtendedKey` 3, `BlsKey` 2.

By contrast cardano-node's entire credential path uses one role (`StakePoolKey`) and this surface:
`readFileTextEnvelope`, `deserialiseFromTextEnvelope`, `File`, `FileError`, `TextEnvelope`,
`TextEnvelopeError`, `OperationalCertificate`, `getHotKey`, `SigningKey KesKey`, `SigningKey VrfKey`,
`StakePoolVerificationKey`, `verificationKeyHash`, `getVerificationKey`. That asymmetry is why
stage 1 can be small while the end state is complete.
