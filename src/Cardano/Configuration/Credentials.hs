-- | Reading the block-forging credentials named by 'Credentials'.
--
-- This is the node-facing half of the key layer: 'Cardano.Key' and
-- 'Cardano.Serialise' (the @cardano-config:keys@ component) turn bytes into key
-- material and do no IO at all; this module opens the files that
-- 'Cardano.Configuration.CliArgs.Credentials' points at and decodes them.
--
-- The logic is ported from @cardano-node@'s
-- @Cardano.Node.Protocol.Shelley.readLeaderCredentials@ and
-- @Cardano.Node.Protocol.Byron.readLeaderCredentials@. What stays in
-- @cardano-node@ (and in @ouroboros-consensus@) is only the final wrap of the
-- results below into the consensus types @ShelleyLeaderCredentials@ and
-- @ByronLeaderCredentials@, which this package cannot mention: @cardano-config@
-- sits below @ouroboros-consensus@, not above it.
module Cardano.Configuration.Credentials
  ( -- * Reading credentials
    readCredentials

    -- * Decoded credentials
  , DecodedCredentials (..)
  , ByronCredentials (..)
  , ShelleyCredentials (..)
  , KESCredentials (..)

    -- * Errors
  , CredentialsError (..)
  , renderCredentialsError
  ) where

import Cardano.Chain.Delegation (Certificate)
import Cardano.Configuration.CliArgs (Credentials, KESSource (..))
import qualified Cardano.Configuration.CliArgs as CLI
import Cardano.Key.Byron (AsType (AsByronKey), ByronKey)
import Cardano.Key.Class (AsType (AsSigningKey), Key (..))
import Cardano.Key.OperationalCertificate (OperationalCertificate, getHotKey)
import Cardano.Key.Praos (KesKey, VrfKey)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Prelude (canonicalDecodePretty)
import Cardano.Serialise.Raw (deserialiseFromRawBytes)
import Cardano.Serialise.TextEnvelope
  ( HasTextEnvelope
  , TextEnvelope
  , TextEnvelopeError
  , deserialiseFromTextEnvelope
  , deserialiseFromTextEnvelopeJSON
  , renderTextEnvelopeError
  )
import Control.Exception (IOException, try)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import qualified Data.Aeson as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as Text

-- | Everything 'readCredentials' could decode: at most one set of Byron
-- credentials, and any number of Shelley ones.
--
-- 'shelleyCredentials' is the singleton credentials given on the command line
-- (if any) /followed by/ every entry of the bulk credentials file. The two are
-- concatenated, not alternatives — a node may be given both.
data DecodedCredentials = DecodedCredentials
  { byronCredentials :: Maybe ByronCredentials
  , shelleyCredentials :: [ShelleyCredentials]
  }
  deriving Show

-- | Byron-era forging credentials: a delegation certificate and the signing key
-- it delegates to.
--
-- Neither file is a text envelope: the signing key is raw bytes in the legacy
-- Byron @XPrv@ format, and the delegation certificate is canonical JSON (the
-- same encoding as the Byron genesis).
data ByronCredentials = ByronCredentials
  { byronCertificate :: Certificate
  , byronSigningKey :: SigningKey ByronKey
  }
  deriving Show

-- | One set of Shelley-era forging credentials.
data ShelleyCredentials = ShelleyCredentials
  { operationalCertificate :: OperationalCertificate
  , vrfSigningKey :: SigningKey VrfKey
  , kesCredentials :: KESCredentials
  , credentialsLabel :: Text
  -- ^ Where these credentials came from, for error messages: the operational
  -- certificate's path for command-line credentials, or @\<file\>.\<index\>@
  -- for an entry of a bulk credentials file.
  --
  -- This is /not/ the consensus @shelleyLeaderCredentialsLabel@. @cardano-node@
  -- sets that to the constant @\"Shelley\"@ for both paths, and a consumer
  -- building @ShelleyLeaderCredentials@ should keep doing so.
  }
  deriving Show

-- | Where the KES signing key for a set of Shelley credentials comes from.
data KESCredentials
  = -- | Read from a key file and cross-checked against the operational
    -- certificate.
    KESCredentialsKey (SigningKey KesKey)
  | -- | A KES agent's socket path, passed through unchecked. See the note on
    -- 'readCredentials' about what is /not/ verified in this case.
    KESCredentialsAgent FilePath
  deriving Show

-- | The errors 'readCredentials' can return.
--
-- The constructors mirror @cardano-node@'s @PraosLeaderCredentialsError@ and the
-- credential-related constructors of its @ByronProtocolInstantiationError@, so
-- that the messages a node prints do not change.
data CredentialsError
  = -- | A credentials file could not be read.
    CredentialsReadError !FilePath !IOException
  | -- | A bulk credentials file was not valid JSON, or not a list of envelope
    -- triples.
    EnvelopeParseError !FilePath !String
  | -- | A text envelope was of the wrong type, or its CBOR payload would not
    -- decode.
    CredentialsEnvelopeError !FilePath !TextEnvelopeError
  | -- | An operational certificate was not specified, but a VRF or KES key was.
    OCertNotSpecified
  | -- | A VRF key was not specified, but an operational certificate or KES key
    -- was.
    VRFKeyNotSpecified
  | -- | A KES key was not specified, but an operational certificate or VRF key
    -- was.
    KESKeyNotSpecified
  | -- | The KES key file does not contain the key named by the operational
    -- certificate. Order: KES signing key, operational certificate.
    MismatchedKesKey !FilePath !FilePath
  | -- | A Byron signing key was specified without its delegation certificate.
    ByronDelegationCertificateFilepathNotSpecified
  | -- | A Byron delegation certificate was specified without its signing key.
    ByronSigningKeyFilepathNotSpecified
  | -- | A Byron signing key was not in the legacy @XPrv@ raw format.
    ByronSigningKeyDeserialiseFailure !FilePath
  | -- | A Byron delegation certificate was not valid canonical JSON.
    ByronCanonicalDecodeFailure !FilePath !Text
  deriving Show

-- | Render a 'CredentialsError' as human-readable text.
--
-- Following this repository's convention (and so that the keys layer stays free
-- of @prettyprinter@), errors carry a renderer rather than an @Error@ or
-- @Pretty@ instance.
renderCredentialsError :: CredentialsError -> Text
renderCredentialsError = \case
  CredentialsReadError fp err ->
    "There was an error reading a credentials file: "
      <> textShow fp
      <> " Error: "
      <> textShow err
  EnvelopeParseError fp err ->
    "There was an error parsing a credentials envelope: "
      <> textShow fp
      <> " Error: "
      <> textShow err
  CredentialsEnvelopeError fp err ->
    Text.pack fp <> ": " <> renderTextEnvelopeError err
  OCertNotSpecified -> missingFlagMessage "shelley-operational-certificate"
  VRFKeyNotSpecified -> missingFlagMessage "shelley-vrf-key"
  KESKeyNotSpecified -> missingFlagMessage "shelley-kes-key"
  MismatchedKesKey kesFp certFp ->
    "The KES key provided at: "
      <> textShow kesFp
      <> " does not match the KES key specified in the operational certificate at: "
      <> textShow certFp
  ByronDelegationCertificateFilepathNotSpecified ->
    "Delegation certificate filepath not specified"
  ByronSigningKeyFilepathNotSpecified ->
    "Signing key filepath not specified"
  ByronSigningKeyDeserialiseFailure fp ->
    "Signing key deserialisation error in: " <> textShow fp
  ByronCanonicalDecodeFailure fp failure ->
    "Canonical decode failure in " <> textShow fp <> " Canonical failure: " <> textShow failure
 where
  missingFlagMessage flag =
    "To create blocks, the --" <> flag <> " must also be specified"

textShow :: Show a => a -> Text
textShow = Text.pack . show

-- | Read and decode every credential file named by 'Credentials'.
--
-- The Shelley command-line credentials are all-or-none: supplying none of
-- @--shelley-operational-certificate@, @--shelley-vrf-key@ and the KES source is
-- fine (the node is then not a block producer on that path), supplying all three
-- is fine, and supplying some but not all is an error naming the missing one.
--
-- When the KES key comes from a file, the operational certificate's hot key is
-- checked against it and a mismatch is a 'MismatchedKesKey' error.
--
-- Entries of a bulk credentials file are cross-checked the same way. This
-- diverges from @cardano-node@, whose bulk path never calls the equivalent of
-- @opCertKesKeyCheck@, so a bulk file it accepts today is rejected here.
--
-- One check is still /not/ done, matching @cardano-node@: with a KES /agent/ the
-- operational certificate is not checked against the agent's key, because the
-- key never leaves the agent for the node to derive a verification key from
-- (@cardano-node@'s @Cardano.Node.Protocol.Shelley@ carries a
-- @TODO: minor yikes@ about this).
readCredentials :: Credentials -> IO (Either CredentialsError DecodedCredentials)
readCredentials creds = runExceptT $ do
  byron <- readByronCredentials creds
  -- The set of credentials is the sum total of what comes from the command line
  -- and what is in the bulk credentials file.
  singleton <- readShelleyCredentialsSingleton creds
  bulk <- readShelleyCredentialsBulk creds
  pure
    DecodedCredentials
      { byronCredentials = byron
      , shelleyCredentials = singleton <> bulk
      }

--
-- Byron
--

readByronCredentials ::
  Credentials -> ExceptT CredentialsError IO (Maybe ByronCredentials)
readByronCredentials creds =
  case (CLI.byronDelegationCertificateFile creds, CLI.byronSigningKeyFile creds) of
    (SNothing, SNothing) -> pure Nothing
    (SJust _, SNothing) -> throwE ByronSigningKeyFilepathNotSpecified
    (SNothing, SJust _) -> throwE ByronDelegationCertificateFilepathNotSpecified
    (SJust delegCertFile, SJust signingKeyFile) -> do
      signingKeyBytes <- readFileBytes signingKeyFile
      delegCertBytes <- readFileLazyBytes delegCertFile
      signingKey <-
        except
          . first (const (ByronSigningKeyDeserialiseFailure signingKeyFile))
          $ deserialiseFromRawBytes (AsSigningKey AsByronKey) signingKeyBytes
      delegCert <-
        except
          . first (ByronCanonicalDecodeFailure delegCertFile)
          $ canonicalDecodePretty delegCertBytes
      pure $
        Just
          ByronCredentials
            { byronCertificate = delegCert
            , byronSigningKey = signingKey
            }

--
-- Shelley, from the command line
--

readShelleyCredentialsSingleton ::
  Credentials -> ExceptT CredentialsError IO [ShelleyCredentials]
readShelleyCredentialsSingleton creds =
  case (CLI.shelleyOperationalCertificate creds, CLI.shelleyVRFKey creds, CLI.shelleyKES creds) of
    -- It is OK to supply none of the files on the command line.
    (SNothing, SNothing, SNothing) -> pure []
    -- Or to supply all of them.
    (SJust opCertFile, SJust vrfFile, SJust kesSource) -> do
      vrfSKey <- readEnvelopeFile vrfFile
      (opCert, kesCreds) <- case kesSource of
        KESKeyFilePath kesFile -> do
          (cert, kesKey) <- opCertKesKeyCheck kesFile opCertFile
          pure (cert, KESCredentialsKey kesKey)
        -- With an agent we only read the operational certificate; see the note
        -- on 'readCredentials' about the check that is missing here.
        KESAgentSocketPath socketFile -> do
          cert <- readEnvelopeFile opCertFile
          pure (cert, KESCredentialsAgent socketFile)
      pure
        [ ShelleyCredentials
            { operationalCertificate = opCert
            , vrfSigningKey = vrfSKey
            , kesCredentials = kesCreds
            , credentialsLabel = Text.pack opCertFile
            }
        ]
    -- But not OK to supply some of the files without the others.
    (SNothing, _, _) -> throwE OCertNotSpecified
    (_, SNothing, _) -> throwE VRFKeyNotSpecified
    (_, _, SNothing) -> throwE KESKeyNotSpecified

-- | Read an operational certificate and a KES signing key, and check that the
-- certificate names that key.
opCertKesKeyCheck ::
  -- | KES key
  FilePath ->
  -- | Operational certificate
  FilePath ->
  ExceptT CredentialsError IO (OperationalCertificate, SigningKey KesKey)
opCertKesKeyCheck kesFile certFile = do
  opCert <- readEnvelopeFile certFile
  kesSKey <- readEnvelopeFile kesFile
  except $ opCertNamesKesKey kesFile certFile opCert kesSKey
  pure (opCert, kesSKey)

-- | Check that the KES key named by an operational certificate is the one that
-- was supplied alongside it.
--
-- The certificate is the cold key's signed statement that one particular KES key
-- may forge on its behalf, but nothing ties it to the KES file handed to the
-- node. A stale certificate paired with a rotated KES key would forge blocks the
-- certificate does not authorise, and the network rejects every one of them.
opCertNamesKesKey ::
  -- | KES key, for the error message
  FilePath ->
  -- | Operational certificate, for the error message
  FilePath ->
  OperationalCertificate ->
  SigningKey KesKey ->
  Either CredentialsError ()
opCertNamesKesKey kesLoc certLoc opCert kesSKey
  | suppliedKesKeyHash /= opCertSpecifiedKesKeyHash = Left (MismatchedKesKey kesLoc certLoc)
  | otherwise = Right ()
 where
  opCertSpecifiedKesKeyHash = verificationKeyHash (getHotKey opCert)
  suppliedKesKeyHash = verificationKeyHash (getVerificationKey kesSKey)

--
-- Shelley, from a bulk credentials file
--

-- | One entry of a bulk credentials file: the operational certificate, VRF key
-- and KES key envelopes, each paired with a label naming where it came from.
data BulkEntry = BulkEntry
  { beCert :: (TextEnvelope, FilePath)
  , beVrf :: (TextEnvelope, FilePath)
  , beKes :: (TextEnvelope, FilePath)
  , beLabel :: Text
  }

readShelleyCredentialsBulk ::
  Credentials -> ExceptT CredentialsError IO [ShelleyCredentials]
readShelleyCredentialsBulk creds =
  traverse parseBulkEntry =<< readBulkFile (CLI.bulkCredentialsFile creds)
 where
  parseBulkEntry :: BulkEntry -> ExceptT CredentialsError IO ShelleyCredentials
  parseBulkEntry BulkEntry{beCert, beVrf, beKes, beLabel} = do
    opCert <- parseEnvelope beCert
    kesKey <- parseEnvelope beKes
    vrfSKey <- parseEnvelope beVrf
    -- Unlike @cardano-node@, which only cross-checks the command-line
    -- credentials, every bulk entry is checked too. See 'readCredentials'.
    except $ opCertNamesKesKey (snd beKes) (snd beCert) opCert kesKey
    pure
      ShelleyCredentials
        { operationalCertificate = opCert
        , vrfSigningKey = vrfSKey
        , kesCredentials = KESCredentialsKey kesKey
        , credentialsLabel = beLabel
        }

  readBulkFile :: StrictMaybe FilePath -> ExceptT CredentialsError IO [BulkEntry]
  readBulkFile SNothing = pure []
  readBulkFile (SJust fp) = do
    content <- readFileBytes fp
    envelopes <-
      except . first (EnvelopeParseError fp) $ Aeson.eitherDecodeStrict' content
    pure $ zipWith (mkEntry fp) [0 :: Int ..] envelopes

  mkEntry :: FilePath -> Int -> (TextEnvelope, TextEnvelope, TextEnvelope) -> BulkEntry
  mkEntry fp ix (teCert, teVrf, teKes) =
    BulkEntry
      { beCert = (teCert, loc "cert")
      , beVrf = (teVrf, loc "vrf")
      , beKes = (teKes, loc "kes")
      , beLabel = Text.pack (fp <> "." <> show ix)
      }
   where
    loc ty = fp <> "." <> show ix <> ty

parseEnvelope ::
  HasTextEnvelope a => (TextEnvelope, FilePath) -> ExceptT CredentialsError IO a
parseEnvelope (te, loc) =
  except . first (CredentialsEnvelopeError loc) $ deserialiseFromTextEnvelope te

--
-- File reading
--

-- | Read a text-envelope file and decode it.
--
-- @cardano-config:keys@ is pure, so unlike @cardano-api@'s
-- @readFileTextEnvelope@ this does its own IO.
readEnvelopeFile :: HasTextEnvelope a => FilePath -> ExceptT CredentialsError IO a
readEnvelopeFile fp = do
  content <- readFileBytes fp
  except . first (CredentialsEnvelopeError fp) $ deserialiseFromTextEnvelopeJSON content

readFileBytes :: FilePath -> ExceptT CredentialsError IO ByteString
readFileBytes fp = readFileWith BS.readFile fp

readFileLazyBytes :: FilePath -> ExceptT CredentialsError IO LBS.ByteString
readFileLazyBytes fp = readFileWith LBS.readFile fp

-- | Read a file, turning an 'IOException' into a 'CredentialsReadError'.
--
-- @cardano-node@ catches read failures on the bulk credentials file but lets
-- them escape as exceptions on the Byron paths; here every credential file is
-- read the same way.
readFileWith ::
  (FilePath -> IO a) -> FilePath -> ExceptT CredentialsError IO a
readFileWith rd fp =
  ExceptT $ first (CredentialsReadError fp) <$> try (rd fp)
