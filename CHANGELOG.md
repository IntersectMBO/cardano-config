# Revision history for cardano-config

## Unreleased

### `cardano-config:keys` -- a new public sublibrary

The Cardano key and credential decoding layer, moved out of `cardano-api` so that
one implementation parses Cardano key material. Repositories that cannot depend
on `cardano-api` (notably `ouroboros-consensus`, which sits *below* it) no longer
have to fork it.

The component is pure: no IO, no filesystem, no presentation. It carries the full
role catalogue (all 26 key roles and witness types, not just the three the node
forges with), the `HasTypeProxy`/`SerialiseAsCBOR`/`SerialiseAsRawBytes`/
`HasTextEnvelope`/`Key` classes and their instances, and operational certificate
decoding:

  * `Cardano.Config.Key.{HasTypeProxy,Hash,Class,Shelley,Praos,Leios,Byron,OperationalCertificate}`
  * `Cardano.Config.Serialise.{Cbor,Raw,Using,TextEnvelope,Orphans}`

Bech32, CIP-129, mnemonics, the `File`/`FileError` IO layer and the `Error`/
`Pretty` instances deliberately stay in `cardano-api`. Following this repository's
convention, error types here carry a `renderX :: X -> Text` instead of an `Error`
instance.

### `Cardano.Configuration.Credentials`

`readCredentials` reads the block-forging credentials named by the existing
`CliArgs.Credentials` record: the Byron delegation certificate and signing key, the
Shelley KES/VRF keys and operational certificate, and a bulk credentials file.
Ported from `cardano-node`'s `Cardano.Node.Protocol.{Shelley,Byron}`, which keeps
only the wrap of the results into the consensus `ShelleyLeaderCredentials` and
`ByronLeaderCredentials`.

One deliberate divergence from `cardano-node`: the operational
certificate/KES-key cross-check is applied to **every** set of credentials,
including each entry of a bulk credentials file. `cardano-node` only checks the
credentials given on the command line, so a bulk file whose entries do not match
starts a node that signs blocks with a KES key its operational certificate does
not authorise — the network rejects every one of them. Such a file is now
rejected at startup with `MismatchedKesKey`, naming the offending entry.

The remaining unchecked case matches `cardano-node`: with a KES *agent* the
operational certificate cannot be checked against the agent's key, because the
key never leaves the agent.

### Breaking

* `Cardano.Configuration.CliArgs.Credentials`: two fields are renamed, so that
  the ones holding a path say so.

    * `byronSigningKey` becomes `byronSigningKeyFile`. The old name collided with
      `ByronCredentials.byronSigningKey`, which holds the *decoded* key, so a
      module using both records could not import them unqualified.
    * `byronDelegationCertificate` becomes `byronDelegationCertificateFile`, for
      symmetry with the above.

  The `--byron-signing-key` and `--byron-delegation-certificate` command-line
  flags are unchanged, as are the `ByronSigningKey` and
  `ByronDelegationCertificate` keys in the rendered configuration.

## 1.0.0.0 -- 2026-07-31

First release
