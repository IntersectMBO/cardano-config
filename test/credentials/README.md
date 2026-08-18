# Credential test fixtures

Real key material, not hand-rolled: a fixture built by this package's own
encoder would round-trip through its own decoder and prove nothing. Generated
with `cardano-cli 11.0.0.0` (git rev `01a89dad991e5a19990150b4e1de348a1481a37a`).

| File | What it is |
|---|---|
| `opcert.cert` | operational certificate naming `kes.skey`'s verification key |
| `kes.skey` | the KES signing key `opcert.cert` names |
| `kes-other.skey` | an unrelated KES key, so the opcert cross-check can be shown to fail |
| `vrf.skey` | VRF signing key |
| `bulk.creds` | a bulk credentials file with two distinct `(opcert, vrf, kes)` entries |
| `bulk-mismatched.creds` | `bulk.creds` with entry 0's KES key swapped for `kes-other.skey`, so the per-entry cross-check can be shown to fail |
| `byron-delegation.cert` | Byron delegation certificate (canonical JSON) |
| `byron-delegate.key` | the Byron delegate signing key it delegates to (legacy `XPrv`) |

## Regenerating

The Shelley triple, plus a second one and the unrelated KES key:

```sh
cardano-cli node key-gen --cold-verification-key-file cold.vkey \
  --cold-signing-key-file cold.skey \
  --operational-certificate-issue-counter-file cold.counter
cardano-cli node key-gen-KES --verification-key-file kes.vkey --signing-key-file kes.skey
cardano-cli node key-gen-VRF --verification-key-file vrf.vkey --signing-key-file vrf.skey
cardano-cli node key-gen-KES --verification-key-file kes-other.vkey \
  --signing-key-file kes-other.skey
cardano-cli node issue-op-cert --kes-verification-key-file kes.vkey \
  --cold-signing-key-file cold.skey \
  --operational-certificate-issue-counter-file cold.counter \
  --kes-period 0 --out-file opcert.cert
```

`bulk.creds` is a JSON array of `[opcert, vrf.skey, kes.skey]` envelope triples —
two entries, the second built from an independently generated cold/KES/VRF set.
`bulk-mismatched.creds` is the same file with entry 0's third element replaced by
`kes-other.skey`.

The Byron pair comes out of a throwaway Byron genesis, which is the only
`cardano-cli 11` command that still emits delegation certificates
(`byron delegation new-certificate` was removed):

```sh
cardano-cli byron genesis genesis --genesis-output-dir g \
  --start-time 1600000000 --protocol-parameters-file protocol-params.json \
  --k 2160 --protocol-magic 42 --n-poor-addresses 1 --n-delegate-addresses 2 \
  --total-balance 1000000000 --delegate-share 0.9 \
  --avvm-entry-count 0 --avvm-entry-balance 0 --secret-seed 1234
cp g/delegation-cert.000.json byron-delegation.cert
cp g/delegate-keys.000.key    byron-delegate.key
```

These keys secure nothing: they exist only to be parsed by the test suite.
