{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Tests for the key layer moved out of @cardano-api@ (@cardano-config:keys@)
-- and for 'readCredentials'.
--
-- The fixtures under @test\/credentials@ are real key material generated with
-- @cardano-cli@, not hand-rolled: a fixture built by this package's own encoder
-- would round-trip through its own decoder and prove nothing. That directory's
-- README records how to regenerate them.
--
-- @kes.skey@ is the KES key named by @opcert.cert@; @kes-other.skey@ is an
-- unrelated KES key, so the cross-check can be shown to fail as well as to pass.
module Test.Credentials (tests) where

import Cardano.Binary (DecoderError (..))
import Cardano.Configuration.CliArgs (Credentials (..), KESSource (..), emptyCredentials)
import Cardano.Configuration.Credentials
  ( CredentialsError (..)
  , DecodedCredentials (..)
  , KESCredentials (..)
  , ShelleyCredentials (..)
  , readCredentials
  , renderCredentialsError
  )
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Key.Byron (AsType (AsByronKey), ByronKey, ByronKeyLegacy)
import Cardano.Key.Class (Key (..))
import Cardano.Key.HasTypeProxy (asType)
import Cardano.Key.Leios (BlsKey, BlsPossessionProof)
import Cardano.Key.OperationalCertificate
  ( OperationalCertificate
  , OperationalCertificateIssueCounter
  , getHotKey
  )
import Cardano.Key.Praos (KesKey, VrfKey)
import Cardano.Key.Shelley
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Serialise.Cbor (deserialiseFromCBOR, serialiseToCBOR)
import Cardano.Serialise.TextEnvelope
  ( HasTextEnvelope
  , TextEnvelopeDescr (..)
  , TextEnvelopeError (..)
  , TextEnvelopeType (..)
  , renderTextEnvelopeError
  , textEnvelopeType
  )
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Paths_cardano_config (getDataFileName)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)

tests :: IO TestTree
tests = do
  creds <- credentialTests
  pure $
    testGroup
      "keys"
      [ envelopeTypeTests
      , renderTextEnvelopeErrorTests
      , byronKeyCborTests
      , creds
      ]

--
-- The role catalogue
--

-- | Every 'HasTextEnvelope' instance in the moved catalogue, pinned to the exact
-- @type@ string it writes into a text envelope.
--
-- These strings are the on-disk format, shared with every key file
-- @cardano-cli@ has written, so changing one is a silent incompatibility.
envelopeTypeTests :: TestTree
envelopeTypeTests =
  testGroup
    "text envelope types"
    [ testCase (Text.unpack expected) $
        assertEqual "envelope type" (TextEnvelopeType (Text.unpack expected)) actual
    | (expected, actual) <- envelopeTypeTable
    ]

envelopeTypeTable :: [(Text, TextEnvelopeType)]
envelopeTypeTable =
  [ -- Payment
    ("PaymentVerificationKeyShelley_ed25519", ty @(VerificationKey PaymentKey))
  , ("PaymentSigningKeyShelley_ed25519", ty @(SigningKey PaymentKey))
  , ("PaymentExtendedVerificationKeyShelley_ed25519_bip32", ty @(VerificationKey PaymentExtendedKey))
  , ("PaymentExtendedSigningKeyShelley_ed25519_bip32", ty @(SigningKey PaymentExtendedKey))
  , -- Stake
    ("StakeVerificationKeyShelley_ed25519", ty @(VerificationKey StakeKey))
  , ("StakeSigningKeyShelley_ed25519", ty @(SigningKey StakeKey))
  , ("StakeExtendedVerificationKeyShelley_ed25519_bip32", ty @(VerificationKey StakeExtendedKey))
  , ("StakeExtendedSigningKeyShelley_ed25519_bip32", ty @(SigningKey StakeExtendedKey))
  , -- Genesis
    ("GenesisVerificationKey_ed25519", ty @(VerificationKey GenesisKey))
  , ("GenesisSigningKey_ed25519", ty @(SigningKey GenesisKey))
  , ("GenesisExtendedVerificationKey_ed25519_bip32", ty @(VerificationKey GenesisExtendedKey))
  , ("GenesisExtendedSigningKey_ed25519_bip32", ty @(SigningKey GenesisExtendedKey))
  , ("GenesisDelegateVerificationKey_ed25519", ty @(VerificationKey GenesisDelegateKey))
  , ("GenesisDelegateSigningKey_ed25519", ty @(SigningKey GenesisDelegateKey))
  ,
    ( "GenesisDelegateExtendedVerificationKey_ed25519_bip32"
    , ty @(VerificationKey GenesisDelegateExtendedKey)
    )
  , ("GenesisDelegateExtendedSigningKey_ed25519_bip32", ty @(SigningKey GenesisDelegateExtendedKey))
  , ("GenesisUTxOVerificationKey_ed25519", ty @(VerificationKey GenesisUTxOKey))
  , ("GenesisUTxOSigningKey_ed25519", ty @(SigningKey GenesisUTxOKey))
  , -- Stake pool
    ("StakePoolVerificationKey_ed25519", ty @(VerificationKey StakePoolKey))
  , ("StakePoolSigningKey_ed25519", ty @(SigningKey StakePoolKey))
  , ("StakePoolExtendedVerificationKey_ed25519_bip32", ty @(VerificationKey StakePoolExtendedKey))
  , ("StakePoolExtendedSigningKey_ed25519_bip32", ty @(SigningKey StakePoolExtendedKey))
  , -- DRep
    ("DRepVerificationKey_ed25519", ty @(VerificationKey DRepKey))
  , ("DRepSigningKey_ed25519", ty @(SigningKey DRepKey))
  , ("DRepExtendedVerificationKey_ed25519_bip32", ty @(VerificationKey DRepExtendedKey))
  , ("DRepExtendedSigningKey_ed25519_bip32", ty @(SigningKey DRepExtendedKey))
  , -- Constitutional committee
    ("ConstitutionalCommitteeColdVerificationKey_ed25519", ty @(VerificationKey CommitteeColdKey))
  , ("ConstitutionalCommitteeColdSigningKey_ed25519", ty @(SigningKey CommitteeColdKey))
  ,
    ( "ConstitutionalCommitteeColdExtendedVerificationKey_ed25519_bip32"
    , ty @(VerificationKey CommitteeColdExtendedKey)
    )
  ,
    ( "ConstitutionalCommitteeColdExtendedSigningKey_ed25519_bip32"
    , ty @(SigningKey CommitteeColdExtendedKey)
    )
  , ("ConstitutionalCommitteeHotVerificationKey_ed25519", ty @(VerificationKey CommitteeHotKey))
  , ("ConstitutionalCommitteeHotSigningKey_ed25519", ty @(SigningKey CommitteeHotKey))
  ,
    ( "ConstitutionalCommitteeHotExtendedVerificationKey_ed25519_bip32"
    , ty @(VerificationKey CommitteeHotExtendedKey)
    )
  ,
    ( "ConstitutionalCommitteeHotExtendedSigningKey_ed25519_bip32"
    , ty @(SigningKey CommitteeHotExtendedKey)
    )
  , -- Praos consensus keys
    ("KesVerificationKey_ed25519_kes_2^6", ty @(VerificationKey KesKey))
  , ("KesSigningKey_ed25519_kes_2^6", ty @(SigningKey KesKey))
  , ("VrfVerificationKey_PraosVRF", ty @(VerificationKey VrfKey))
  , ("VrfSigningKey_PraosVRF", ty @(SigningKey VrfKey))
  , -- Leios

    ( "BlsVerificationKey_bls12-381-BLS-Signature-Mininimal-Signature-Size"
    , ty @(VerificationKey BlsKey)
    )
  , ("BlsSigningKey_bls12-381-BLS-Signature-Mininimal-Signature-Size", ty @(SigningKey BlsKey))
  , ("BlsPossessionProof_bls12-381-BLS-Signature-Mininimal-Signature-Size", ty @BlsPossessionProof)
  , -- Byron
    ("PaymentVerificationKeyByron_ed25519_bip32", ty @(VerificationKey ByronKey))
  , ("PaymentSigningKeyByron_ed25519_bip32", ty @(SigningKey ByronKey))
  , ("PaymentVerificationKeyByronLegacy_ed25519_bip32", ty @(VerificationKey ByronKeyLegacy))
  , ("PaymentSigningKeyByronLegacy_ed25519_bip32", ty @(SigningKey ByronKeyLegacy))
  , -- Operational certificates
    ("NodeOperationalCertificate", ty @OperationalCertificate)
  , ("NodeOperationalCertificateIssueCounter", ty @OperationalCertificateIssueCounter)
  ]

ty :: forall a. HasTextEnvelope a => TextEnvelopeType
ty = textEnvelopeType (asType @a)

--
-- Error rendering
--

-- | The strings 'renderTextEnvelopeError' produces, pinned against
-- @cardano-api@'s golden files under
-- @test\/cardano-api-golden\/files\/errors\/Cardano.Api.Serialise.TextEnvelope.Internal.TextEnvelopeError@.
--
-- @cardano-api@ renders these through its @Error@ class; this package has no
-- @Error@ or @Pretty@ instances, so the same text has to come out of
-- 'renderTextEnvelopeError' instead.
renderTextEnvelopeErrorTests :: TestTree
renderTextEnvelopeErrorTests =
  testGroup
    "renderTextEnvelopeError"
    [ golden
        "TextEnvelopeAesonDecodeError"
        (TextEnvelopeAesonDecodeError "<string>")
        "TextEnvelope aeson decode error: <string>"
    , golden
        "TextEnvelopeDecodeError"
        (TextEnvelopeDecodeError DecoderErrorVoid)
        "TextEnvelope decode error: DecoderErrorVoid"
    , golden
        "TextEnvelopeTypeError"
        ( TextEnvelopeTypeError
            [TextEnvelopeType "<string>", TextEnvelopeType "<string>"]
            (TextEnvelopeType "<string>")
        )
        "TextEnvelope type error:  Expected one of: <string>, <string> Actual: <string>"
    , golden
        "TextEnvelopeUnknownKeyWitness"
        (TextEnvelopeUnknownKeyWitness (TextEnvelopeDescr "<string>"))
        "Unknown key witness specified: TextEnvelopeDescr \"<string>\""
    , golden
        "TextEnvelopeUnknownType"
        (TextEnvelopeUnknownType "<string>")
        "Unknown TextEnvelope type: <string>"
    ]
 where
  golden name err expected =
    testCase name $ assertEqual "rendered error" expected (renderTextEnvelopeError err)

--
-- Byron keys
--

-- | Ported from @cardano-api@'s @Test.Cardano.Api.KeysByron@, which round-trips
-- a Byron signing key through CBOR.
--
-- @cardano-api@ generates the seed with hedgehog; this repository's test suite
-- has no hedgehog dependency, so the seed is fixed. The comparison is on the
-- serialised bytes rather than on the key, because @SigningKey ByronKey@ has no
-- 'Eq' instance (@cardano-api@'s test gets one from a test-only orphan).
byronKeyCborTests :: TestTree
byronKeyCborTests =
  testGroup
    "Byron keys"
    [ testCase "roundtrip byron signing key CBOR" $ do
        let seedSize = fromIntegral (deterministicSigningKeySeedSize AsByronKey)
            sk = deterministicSigningKey AsByronKey (mkSeedFromBytes (BS.replicate seedSize 42))
            bytes = serialiseToCBOR sk
        case deserialiseFromCBOR (AsSigningKey AsByronKey) bytes of
          Left err -> assertFailure ("could not decode a Byron signing key: " <> show err)
          Right sk' -> assertEqual "reserialised bytes" bytes (serialiseToCBOR (sk' :: SigningKey ByronKey))
    ]

--
-- Credential reading
--

credentialTests :: IO TestTree
credentialTests = do
  opCert <- fixture "opcert.cert"
  kes <- fixture "kes.skey"
  kesOther <- fixture "kes-other.skey"
  vrf <- fixture "vrf.skey"
  bulk <- fixture "bulk.creds"
  bulkMismatched <- fixture "bulk-mismatched.creds"
  byronCert <- fixture "byron-delegation.cert"
  byronKey <- fixture "byron-delegate.key"
  pure $
    testGroup
      "readCredentials"
      [ testCase "no credentials at all decodes to nothing" $ do
          r <- expectOk emptyCredentials
          assertEqual "no byron credentials" Nothing (fmap (const ()) (byronCredentials r))
          assertEqual "no shelley credentials" 0 (length (shelleyCredentials r))
      , testCase "a KES key file, VRF key and operational certificate decode" $ do
          r <- expectOk (shelleyCreds opCert vrf (KESKeyFilePath kes))
          case shelleyCredentials r of
            [c] -> do
              assertEqual "label is the opcert path" (Text.pack opCert) (credentialsLabel c)
              case kesCredentials c of
                KESCredentialsKey k ->
                  assertEqual
                    "opcert hot key matches the KES key"
                    (verificationKeyHash (getHotKey (operationalCertificate c)))
                    (verificationKeyHash (getVerificationKey k))
                KESCredentialsAgent p -> assertFailure ("expected a key, got an agent socket: " <> p)
            cs -> assertFailure ("expected exactly one set of credentials, got " <> show (length cs))
      , testCase "a KES key that the operational certificate does not name is rejected" $ do
          err <- expectErr (shelleyCreds opCert vrf (KESKeyFilePath kesOther))
          case err of
            MismatchedKesKey kesFp certFp -> do
              assertEqual "names the KES file" kesOther kesFp
              assertEqual "names the opcert file" opCert certFp
            other -> assertFailure ("expected MismatchedKesKey, got " <> show other)
      , testCase "a KES agent socket is passed through unchecked" $ do
          -- Deliberately a path that does not exist: with an agent the reader
          -- does not touch it, and does not cross-check the opcert against it.
          r <- expectOk (shelleyCreds opCert vrf (KESAgentSocketPath "/nonexistent/kes.socket"))
          case shelleyCredentials r of
            [c] -> case kesCredentials c of
              KESCredentialsAgent p -> assertEqual "socket path" "/nonexistent/kes.socket" p
              KESCredentialsKey _ -> assertFailure "expected an agent socket, got a key"
            cs -> assertFailure ("expected exactly one set of credentials, got " <> show (length cs))
      , testCase "an operational certificate on its own is rejected" $ do
          err <- expectErr emptyCredentials{shelleyOperationalCertificate = SJust opCert}
          expectConstructor "VRFKeyNotSpecified" VRFKeyNotSpecified err
      , testCase "a VRF key on its own is rejected" $ do
          err <- expectErr emptyCredentials{shelleyVRFKey = SJust vrf}
          expectConstructor "OCertNotSpecified" OCertNotSpecified err
      , testCase "a KES key on its own is rejected" $ do
          err <- expectErr emptyCredentials{shelleyKES = SJust (KESKeyFilePath kes)}
          expectConstructor "OCertNotSpecified" OCertNotSpecified err
      , testCase "an operational certificate and VRF key without a KES source are rejected" $ do
          err <-
            expectErr
              emptyCredentials
                { shelleyOperationalCertificate = SJust opCert
                , shelleyVRFKey = SJust vrf
                }
          expectConstructor "KESKeyNotSpecified" KESKeyNotSpecified err
      , testCase "a bulk credentials file with two entries decodes" $ do
          r <- expectOk emptyCredentials{bulkCredentialsFile = SJust bulk}
          case shelleyCredentials r of
            [c0, c1] -> do
              assertEqual "first entry label" (Text.pack (bulk <> ".0")) (credentialsLabel c0)
              assertEqual "second entry label" (Text.pack (bulk <> ".1")) (credentialsLabel c1)
              -- Bulk entries always carry a KES key, never an agent socket.
              mapM_ expectKesKey [c0, c1]
              assertBoolMsg
                "the two entries have different hot keys"
                ( verificationKeyHash (getHotKey (operationalCertificate c0))
                    /= verificationKeyHash (getHotKey (operationalCertificate c1))
                )
            cs -> assertFailure ("expected two sets of credentials, got " <> show (length cs))
      , testCase "a bulk entry whose operational certificate does not name its KES key is rejected" $ do
          -- @cardano-node@ accepts this file; see the note on 'readCredentials'.
          err <- expectErr emptyCredentials{bulkCredentialsFile = SJust bulkMismatched}
          case err of
            MismatchedKesKey kesLoc certLoc -> do
              assertEqual "names the KES entry" (bulkMismatched <> ".0kes") kesLoc
              assertEqual "names the opcert entry" (bulkMismatched <> ".0cert") certLoc
            other -> assertFailure ("expected MismatchedKesKey, got " <> show other)
      , testCase "command-line and bulk credentials are concatenated, not alternatives" $ do
          r <-
            expectOk
              (shelleyCreds opCert vrf (KESKeyFilePath kes)){bulkCredentialsFile = SJust bulk}
          assertEqual "singleton plus both bulk entries" 3 (length (shelleyCredentials r))
      , testCase "a missing credentials file is reported, not thrown" $ do
          err <- expectErr emptyCredentials{bulkCredentialsFile = SJust "/nonexistent/bulk.creds"}
          case err of
            CredentialsReadError fp _ -> assertEqual "names the file" "/nonexistent/bulk.creds" fp
            other -> assertFailure ("expected CredentialsReadError, got " <> show other)
      , testCase "a Byron delegation certificate and signing key decode" $ do
          r <-
            expectOk
              emptyCredentials
                { byronDelegationCertificateFile = SJust byronCert
                , byronSigningKeyFile = SJust byronKey
                }
          case byronCredentials r of
            Just _ -> pure ()
            Nothing -> assertFailure "expected Byron credentials"
      , testCase "a corrupt Byron delegation certificate is reported" $ do
          -- The operational certificate is a text envelope, not canonical JSON,
          -- so it stands in for a malformed delegation certificate.
          err <-
            expectErr
              emptyCredentials
                { byronDelegationCertificateFile = SJust opCert
                , byronSigningKeyFile = SJust byronKey
                }
          case err of
            ByronCanonicalDecodeFailure fp _ -> assertEqual "names the file" opCert fp
            other -> assertFailure ("expected ByronCanonicalDecodeFailure, got " <> show other)
      , testCase "a Byron signing key that is not in the legacy XPrv format is reported" $ do
          err <-
            expectErr
              emptyCredentials
                { byronDelegationCertificateFile = SJust byronCert
                , byronSigningKeyFile = SJust opCert
                }
          case err of
            ByronSigningKeyDeserialiseFailure fp -> assertEqual "names the file" opCert fp
            other -> assertFailure ("expected ByronSigningKeyDeserialiseFailure, got " <> show other)
      , testCase "a Byron signing key without its delegation certificate is rejected" $ do
          err <- expectErr emptyCredentials{byronSigningKeyFile = SJust "irrelevant"}
          expectConstructor
            "ByronDelegationCertificateFilepathNotSpecified"
            ByronDelegationCertificateFilepathNotSpecified
            err
      , testCase "a Byron delegation certificate without its signing key is rejected" $ do
          err <- expectErr emptyCredentials{byronDelegationCertificateFile = SJust "irrelevant"}
          expectConstructor
            "ByronSigningKeyFilepathNotSpecified"
            ByronSigningKeyFilepathNotSpecified
            err
      ]
 where
  shelleyCreds opCert vrf kes =
    emptyCredentials
      { shelleyOperationalCertificate = SJust opCert
      , shelleyVRFKey = SJust vrf
      , shelleyKES = SJust kes
      }

  expectKesKey c = case kesCredentials c of
    KESCredentialsKey _ -> pure ()
    KESCredentialsAgent p -> assertFailure ("expected a key, got an agent socket: " <> p)

fixture :: FilePath -> IO FilePath
fixture name = getDataFileName ("test/credentials/" <> name)

expectOk :: Credentials -> IO DecodedCredentials
expectOk creds =
  readCredentials creds >>= \case
    Right r -> pure r
    Left err -> assertFailure ("expected success, got: " <> Text.unpack (renderCredentialsError err))

expectErr :: Credentials -> IO CredentialsError
expectErr creds =
  readCredentials creds >>= \case
    Left err -> pure err
    Right _ -> assertFailure "expected a failure, but the credentials decoded"

-- | Compare two errors by their rendered text, which is enough to pin the
-- constructor for the nullary cases and keeps the message under test too.
expectConstructor :: String -> CredentialsError -> CredentialsError -> Assertion
expectConstructor name expected actual =
  assertEqual
    ("expected " <> name)
    (renderCredentialsError expected)
    (renderCredentialsError actual)

assertBoolMsg :: String -> Bool -> Assertion
assertBoolMsg msg b = if b then pure () else assertFailure msg
