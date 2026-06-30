-- | Golden-ish tests: every example configuration must parse through the
-- autodocodec-derived parsers (and the full file pipeline). This is the most
-- reliable validation we have, since the parser shares its codec with the
-- schema.
--
-- The @examples/@ and @schemas/@ fixtures are resolved through
-- 'getDataFileName' (they are packaged as @data-files@), so the tests do not
-- depend on the current working directory and work under @cabal test@, Nix and
-- a source distribution alike.
--
-- The cases form a tasty 'TestTree' of @tasty-hunit@ assertions; 'defaultMain'
-- runs them and sets the process exit code.
module Main (main) where

import Autodocodec (JSONCodec, parseJSONVia, toJSONVia)
import Cardano.Configuration (resolveConfiguration)
import qualified Cardano.Configuration as C
import Cardano.Configuration.CliArgs (CliArgs, parseCliArgs)
import Cardano.Configuration.File
import Cardano.Configuration.File.Storage
  ( LedgerDbBackendSelector (..)
  , LedgerDbConfiguration (..)
  , SnapshotOptions (..)
  , SnapshotPolicy (..)
  , resolveSnapshotPolicy
  )
import Cardano.Configuration.Genesis (GenesisReadError (..), readDijkstraGenesisFile)
import Cardano.Configuration.Genesis.Alonzo (alonzoGenesisCodec)
import Cardano.Configuration.Genesis.Byron (readByronGenesisConfig)
import Cardano.Configuration.Genesis.Conway (conwayGenesisCodec)
import Cardano.Configuration.Genesis.Shelley (shelleyGenesisCodec)
import Cardano.Configuration.Render (GenesisRendering (..), nodeConfigurationToJSON)
import Cardano.Configuration.Schema
  ( configurationSchemasWithDefaults
  , genesisSchemas
  , legacyOneFileConfigSchemaWithDefaults
  , splitConfigSchemaWithDefaults
  )
import Cardano.Crypto.Hash (Blake2b_256, Hash, hashFromTextAsHex)
import Cardano.Crypto.ProtocolMagic (RequiresNetworkMagic (RequiresNoMagic))
import Control.Exception (SomeException, evaluate, try)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecodeFileStrict', parseJSON, toJSON)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither)
import Data.Functor.Identity (runIdentity)
import Data.List (isInfixOf)
import Data.Maybe (fromJust)
import qualified Data.Text as T
import Data.Word (Word64)
import Options.Applicative (defaultPrefs, execParserPure, getParseResult, info)
import Paths_cardano_config (getDataFileName)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase)

main :: IO ()
main = do
  schema <- schemaTests
  defaultMain $ testGroup "cardano-config" (cases <> [schema])

-- | The example/parser/resolver cases, in the order they used to be checked.
cases :: [TestTree]
cases =
  [ decodeCase
      "examples/storage.json"
      (decodeData "examples/storage.json" :: IO (Either String (StorageConfiguration Maybe)))
  , decodeCase
      "examples/consensus.json"
      (decodeData "examples/consensus.json" :: IO (Either String (ConsensusConfiguration Maybe)))
  , decodeCase
      "examples/protocol.json"
      (decodeData "examples/protocol.json" :: IO (Either String (ProtocolConfiguration Maybe)))
  , decodeCase
      "examples/network.json"
      (decodeData "examples/network.json" :: IO (Either String (NetworkConfiguration Maybe)))
  , decodeCase
      "examples/localconnections.json"
      (decodeData "examples/localconnections.json" :: IO (Either String (LocalConnectionsConfig Maybe)))
  , parseCase "examples/fullconfig.json"
  , parseCase "examples/split.json"
  , parseCase "examples/split-all.json"
  , shadowWarnCase
  , subfilePathConfinementCase
  , minNodeVersionCase
  , resolveCase
  , genesisRenderCase
  , roleVariantParityCase
  , roleSelectionCase
  , rolePrecedenceCase
  , roleBeatsBaseDefaultCase
  , mempoolAllUnsetCase
  , mempoolAllSetCase
  , mempoolMixedCase
  , mempoolMixedResolveCase
  , snapshotMithrilResolveCase
  , snapshotResolvePolicyCase
  , mithrilRequiresExportCase
  , lsmDatabasePathDefaultCase
  , dijkstraGenesisDecodeCase
  , dijkstraGenesisHashMismatchCase
  , genesisHashRequiredCase
  , genesisHashPresentCase
  , roundTripCase
      "examples/mainnet-shelley-genesis.json (round-trips against the ledger instances)"
      "examples/mainnet-shelley-genesis.json"
      shelleyGenesisCodec
  , roundTripCase
      "examples/mainnet-alonzo-genesis.json (round-trips against the ledger instances)"
      "examples/mainnet-alonzo-genesis.json"
      alonzoGenesisCodec
  , roundTripCase
      "examples/mainnet-conway-genesis.json (round-trips against the ledger instances)"
      "examples/mainnet-conway-genesis.json"
      conwayGenesisCodec
  , byronGenesisDecodeCase
  ]

-- | Fail the assertion with the message when one is present, otherwise pass.
expectOk :: Maybe String -> Assertion
expectOk = maybe (pure ()) assertFailure

-- | Decode a packaged data file (resolved via 'getDataFileName') through its
-- 'FromJSON' instance.
decodeData :: FromJSON a => FilePath -> IO (Either String a)
decodeData p = getDataFileName p >>= eitherDecodeFileStrict'

-- | Decode a single example via its 'FromJSON' instance, forcing the result.
decodeCase :: Show a => String -> IO (Either String a) -> TestTree
decodeCase label act =
  testCase label $ do
    res <- act
    case res of
      Left err -> assertFailure err
      Right v -> () <$ evaluate (length (show v))

-- | Parse a full configuration file (exercising sub-files).
parseCase :: FilePath -> TestTree
parseCase fp =
  testCase fp $ do
    path <- getDataFileName fp
    res <- try (parseConfigurationFiles path >>= \c -> evaluate (length (show c)))
    expectOk $ case res of
      Left (e :: SomeException) -> Just (show e)
      Right _ -> Nothing

-- | A section sub-file path must be a relative path that resolves to a file
-- within the configuration directory. An absolute path (@\/etc\/passwd@) and one
-- that climbs out of the directory with @..@ are both rejected as invalid paths,
-- so a configuration cannot pull in arbitrary files.
subfilePathConfinementCase :: TestTree
subfilePathConfinementCase =
  testCase "section sub-file paths are confined to the config directory (no absolute, no escaping)" $ do
    absolute <- rejectionMessage "examples/subfile-absolute.json"
    escaping <- rejectionMessage "examples/subfile-escapes.json"
    expectOk $ case (absolute, escaping) of
      (Just a, Just e)
        | "invalid configuration file path" `isInfixOf` a
        , "invalid configuration file path" `isInfixOf` e ->
            Nothing
      _ ->
        Just ("expected both paths rejected as invalid, got " <> show (absolute, escaping))
 where
  -- The error message if parsing was rejected, or 'Nothing' if it wrongly
  -- succeeded.
  rejectionMessage fp = do
    path <- getDataFileName fp
    res <- try (parseConfigurationFiles path)
    pure $ case res of
      Left (e :: SomeException) -> Just (show e)
      Right _ -> Nothing

-- | A top-level key belonging to a component that is also supplied as its own
-- section (here a top-level @DijkstraGenesisFile@ alongside a @TestingConfig@
-- section) is shadowed. Parsing still succeeds, and a 'ShadowedKeys' warning
-- naming the offending key is returned for the caller to surface.
shadowWarnCase :: TestTree
shadowWarnCase =
  testCase "examples/shadow.json (shadowed top-level key returns a warning, still parses)" $ do
    path <- getDataFileName "examples/shadow.json"
    res <- try (parseConfigurationFiles path)
    expectOk $ case res of
      Left (e :: SomeException) -> Just (show e)
      Right (_, warnings)
        | any shadowsDijkstra warnings -> Nothing
        | otherwise ->
            Just ("expected a ShadowedKeys warning for DijkstraGenesisFile, got " <> show warnings)
 where
  shadowsDijkstra (ShadowedKeys sks) =
    (T.pack "TestingConfig", T.pack "DijkstraGenesisFile") `elem` sks
  shadowsDijkstra _ = False

-- | The optional top-level @MinNodeVersion@ annotation is read from the same
-- level as @Version@: from inside the @{ Version, Configuration }@ envelope, and
-- — when the document is not enveloped — from the top level alongside the
-- (section or flat) configuration keys. A document that omits it parses to
-- 'Nothing'.
minNodeVersionCase :: TestTree
minNodeVersionCase =
  testCase "MinNodeVersion is read at the top level (enveloped and legacy), or absent" $ do
    enveloped <- parsedMinNodeVersion "examples/min-node-version.json"
    legacy <- parsedMinNodeVersion "examples/min-node-version-legacy.json"
    absent <- parsedMinNodeVersion "examples/split.json"
    expectOk $
      if enveloped == Just (T.pack "10.5.0")
        && legacy == Just (T.pack "9.1.0")
        && absent == Nothing
        then Nothing
        else
          Just $
            "unexpected MinNodeVersion: enveloped="
              <> show enveloped
              <> " legacy="
              <> show legacy
              <> " absent="
              <> show absent
 where
  parsedMinNodeVersion fp = do
    path <- getDataFileName fp
    (cfg, _) <- parseConfigurationFiles path
    pure (minNodeVersion cfg)

-- | Resolving a parsed configuration with default CLI arguments must succeed and
-- produce a complete (@Identity@) configuration, which exercises that the base
-- defaults populate every resolved field.
resolveCase :: TestTree
resolveCase =
  testCase "resolveConfiguration examples/fullconfig.json" $ do
    path <- getDataFileName "examples/fullconfig.json"
    (cfg, _) <- parseConfigurationFiles path
    case cliArgs [] of
      Nothing -> assertFailure "could not build default CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left err -> assertFailure (show err)
        Right nc -> () <$ evaluate (length (show nc))

-- | With 'IncludeGeneses' the resolved configuration renders the decoded value
-- of every era genesis (Byron via its canonical-JSON form, the rest via their
-- codecs), not just the file references; with 'OmitGeneses' none appear. These
-- are the files read and hash-checked at parse time.
genesisRenderCase :: TestTree
genesisRenderCase =
  testCase "resolve renders era geneses only with IncludeGeneses" $ do
    path <- getDataFileName "examples/fullconfig.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Just ("resolve failed: " <> show e)
        Right nc ->
          let keysOf r = case nodeConfigurationToJSON r nc of
                Object o -> [k | k <- eras, maybe False nonEmpty (KM.lookup (K.fromString k) o)]
                _ -> []
              nonEmpty (Object m) = not (KM.null m)
              nonEmpty _ = False
           in if keysOf IncludeGeneses == eras && null (keysOf OmitGeneses)
                then Nothing
                else Just "geneses not gated correctly by IncludeGeneses/OmitGeneses"
 where
  eras = ["ByronGenesis", "ShelleyGenesis", "AlonzoGenesis", "ConwayGenesis"]

-- | The inline role-default partials must equal the committed variant JSON
-- (Option B parity): they are encoded through the same codec and compared to the
-- raw files, so the Haskell literals cannot drift from the data files.
roleVariantParityCase :: TestTree
roleVariantParityCase =
  testCase "network role defaults match the committed variant JSON" $ do
    bpPath <- getDataFileName "defaults/NetworkConfig.variants/NetworkConfig.blockproducer.json"
    relayPath <- getDataFileName "defaults/NetworkConfig.variants/NetworkConfig.relay.json"
    bp <- eitherDecodeFileStrict' bpPath :: IO (Either String Value)
    relay <- eitherDecodeFileStrict' relayPath :: IO (Either String Value)
    expectOk $ case (bp, relay) of
      (Left e, _) -> Just ("could not read blockproducer.json: " <> e)
      (_, Left e) -> Just ("could not read relay.json: " <> e)
      (Right bpV, Right relayV)
        | toJSON blockProducerRoleDefaults /= bpV ->
            Just "blockProducerRoleDefaults differs from NetworkConfig.blockproducer.json"
        | toJSON relayRoleDefaults /= relayV ->
            Just "relayRoleDefaults differs from NetworkConfig.relay.json"
        | otherwise -> Nothing

-- | The networking role defaults are chosen by credential presence: a credential
-- (here a VRF key) yields the block-producer targets (root 100, known 100,
-- PeerSharing off); no credential yields the relay targets (root 60, known 150,
-- PeerSharing on). These values are the node's @defaultDeadlineTargets@ oracle.
roleSelectionCase :: TestTree
roleSelectionCase =
  testCase "network role defaults selected from credential presence" $ do
    path <- getDataFileName "examples/fullconfig.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case (cliArgs ["--shelley-vrf-key", "vrf.skey"], cliArgs []) of
      (Just bpCli, Just relayCli) ->
        case (resolveConfiguration bpCli cfg, resolveConfiguration relayCli cfg) of
          (Left e, _) -> Just ("block-producer resolve failed: " <> show e)
          (_, Left e) -> Just ("relay resolve failed: " <> show e)
          (Right bpNc, Right relayNc) ->
            let bn = C.networkConfiguration bpNc
                rn = C.networkConfiguration relayNc
                ok =
                  deadlineTargetOfRootPeers bn == Just 100
                    && deadlineTargetOfKnownPeers bn == Just 100
                    && peerSharing bn == Just False
                    && deadlineTargetOfRootPeers rn == Just 60
                    && deadlineTargetOfKnownPeers rn == Just 150
                    && peerSharing rn == Just True
             in if ok
                  then Nothing
                  else Just "resolved role targets do not match the expected block-producer/relay values"
      _ -> Just "could not build CLI arguments"

-- | An explicit file value for a role field wins over the role default, even
-- when credentials are present (block producer). Here PeerSharing and
-- TargetNumberOfRootPeers are set in the file; the remaining role fields still
-- come from the (block-producer) role default.
rolePrecedenceCase :: TestTree
rolePrecedenceCase =
  testCase "explicit file value overrides the role default" $ do
    path <- getDataFileName "examples/role-precedence.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs ["--shelley-vrf-key", "vrf.skey"] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Just ("resolve failed: " <> show e)
        Right nc ->
          let n = C.networkConfiguration nc
           in if peerSharing n == Just True -- file wins over block-producer's False
                && deadlineTargetOfRootPeers n == Just 999 -- file wins over 100
                && deadlineTargetOfKnownPeers n == Just 100 -- unset in file, block-producer default
                then Nothing
                else Just "explicit file values did not take precedence over the role default"

-- | The role default beats a /base/ default for a role field the user did not
-- set: resolution is @base \< role \< user@, so a value present only in the base
-- defaults must not shadow the role default. The base @Network.json@ omits the
-- role fields today, so this pins the ordering rather than relying on that.
roleBeatsBaseDefaultCase :: TestTree
roleBeatsBaseDefaultCase =
  testCase "role default overrides a base default (base < role < user)" $
    expectOk
      ( if peerSharing resolved == Just False -- role's False beats the base's True
          && deadlineTargetOfRootPeers resolved == Just 100 -- role's 100 beats the base's 7
          then Nothing
          else Just ("role default did not override the base default: " <> show resolved)
      )
 where
  -- A base default that sets two role fields, with the user setting nothing. The
  -- merged layer (base defaults plus the user layer) then equals the base here.
  base =
    emptyNetworkConfiguration
      { peerSharing = Just True
      , deadlineTargetOfRootPeers = Just 7
      }
  user = emptyNetworkConfiguration
  resolved = withRoleDefaults blockProducerRoleDefaults user base

-- | All three mempool timeouts unset resolves to the coupled default (1, 1.5, 5).
mempoolAllUnsetCase :: TestTree
mempoolAllUnsetCase =
  testCase "mempool timeouts: all-unset takes the coupled (1, 1.5, 5) default" $
    expectOk
      ( case finalizeMempool (MempoolConfiguration Nothing Nothing Nothing Nothing) of
          Left e -> Just ("unexpected rejection: " <> e)
          Right c
            | runIdentity (mempoolTimeoutSoft c) == 1
            , runIdentity (mempoolTimeoutHard c) == 1.5
            , runIdentity (mempoolTimeoutCapacity c) == 5 ->
                Nothing
            | otherwise -> Just "wrong coupled-default timeout values"
      )

-- | All three mempool timeouts set are preserved unchanged.
mempoolAllSetCase :: TestTree
mempoolAllSetCase =
  testCase "mempool timeouts: all-set are preserved" $
    expectOk
      ( case finalizeMempool (MempoolConfiguration Nothing (Just 2) (Just 3) (Just 4)) of
          Left e -> Just ("unexpected rejection: " <> e)
          Right c
            | runIdentity (mempoolTimeoutSoft c) == 2
            , runIdentity (mempoolTimeoutHard c) == 3
            , runIdentity (mempoolTimeoutCapacity c) == 4 ->
                Nothing
            | otherwise -> Just "set timeout values were not preserved"
      )

-- | A mix of set and unset mempool timeouts is rejected by 'finalizeMempool'.
mempoolMixedCase :: TestTree
mempoolMixedCase =
  testCase "mempool timeouts: a partial set is rejected" $
    expectOk
      ( case finalizeMempool (MempoolConfiguration Nothing (Just 1) Nothing Nothing) of
          Left _ -> Nothing
          Right _ -> Just "expected a partial set of timeouts to be rejected"
      )

-- | The all-or-nothing rule surfaces end-to-end: a configuration that sets only
-- one timeout makes 'resolveConfiguration' fail with a 'ConfigResolutionError'.
mempoolMixedResolveCase :: TestTree
mempoolMixedResolveCase =
  testCase "examples/mempool-mixed.json (partial mempool timeouts rejected on resolve)" $ do
    path <- getDataFileName "examples/mempool-mixed.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left _ -> Nothing
        Right _ -> Just "expected resolution to reject a partial set of mempool timeouts"

-- | Parse @cardano-node@-style CLI arguments for a test (no defaults file is
-- needed; the parser supplies its own).
cliArgs :: [String] -> Maybe CliArgs
cliArgs = getParseResult . execParserPure defaultPrefs (info parseCliArgs mempty)

-- | The snapshot fields, in a fixed order, for comparison.
snapshotFields :: SnapshotOptions -> [Maybe Word64]
snapshotFields o =
  [ snapshotInterval o
  , slotOffset o
  , snapshotRateLimit o
  , minDelay o
  , maxDelay o
  , numOfDiskSnapshots o
  ]

-- | The concrete values the @"Mithril"@ policy resolves to.
mithrilFields :: [Maybe Word64]
mithrilFields = [Just 432000, Just 388800, Just 600, Just 300, Just 600, Just 2]

-- | End-to-end: a configuration that uses the base @"Mithril"@ default and one
-- that sets only a couple of snapshot options both resolve to the full concrete
-- Mithril option set (the partial one inheriting the rest).
snapshotMithrilResolveCase :: TestTree
snapshotMithrilResolveCase =
  testCase "Mithril snapshot policy resolves to concrete values (filling partial overrides)" $ do
    fromMithril <- resolvedOptions "examples/role-precedence.json" -- no Snapshots ⇒ base "Mithril"
    fromPartial <- resolvedOptions "examples/fullconfig.json" -- sets 3 of 6 (= Mithril)
    expectOk $ case (fromMithril, fromPartial) of
      (Right a, Right b)
        | a == mithrilFields && b == mithrilFields -> Nothing
        | otherwise -> Just ("unexpected resolved options: " <> show a <> " / " <> show b)
      (Left e, _) -> Just e
      (_, Left e) -> Just e
 where
  resolvedOptions cfgFile = do
    path <- getDataFileName cfgFile
    (cfg, _) <- parseConfigurationFiles path
    pure $ case cliArgs [] of
      Nothing -> Left "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Left (show e)
        Right nc -> case snapshots (runIdentity (ledgerDbConfiguration (C.storageConfiguration nc))) of
          Just (CustomSnapshotPolicy o) -> Right (snapshotFields o)
          other -> Left ("expected resolved custom snapshot options, got " <> show other)

-- | 'resolveSnapshotPolicy': @"Mithril"@ yields its values, and a partial custom
-- policy keeps the value it set (here a distinct @SnapshotInterval@) while the
-- rest are inherited from Mithril.
snapshotResolvePolicyCase :: TestTree
snapshotResolvePolicyCase =
  testCase "resolveSnapshotPolicy fills a partial custom policy from Mithril" $
    expectOk
      ( let mithril = snapshotFields (resolveSnapshotPolicy MithrilSnapshotPolicy)
            partial = SnapshotOptions (Just 7777) Nothing Nothing Nothing Nothing Nothing
            filled = snapshotFields (resolveSnapshotPolicy (CustomSnapshotPolicy partial))
         in if mithril == mithrilFields && filled == [Just 7777, Just 388800, Just 600, Just 300, Just 600, Just 2]
              then Nothing
              else Just ("unexpected: mithril=" <> show mithril <> " filled=" <> show filled)
      )

-- | The Mithril policy under the V2LSM backend requires an @LSMExportPath@; a
-- configuration that omits it must be rejected by the consistency checks (which
-- run before the Mithril policy is resolved away).
mithrilRequiresExportCase :: TestTree
mithrilRequiresExportCase =
  testCase "Mithril + V2LSM without LSMExportPath is rejected" $ do
    path <- getDataFileName "examples/lsm-mithril-no-export.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left _ -> Nothing
        Right _ -> Just "expected rejection (Mithril needs an LSMExportPath under V2LSM)"

-- | The V2LSM backend defaults its database path to @"lsm"@ when the
-- configuration leaves @LSMDatabasePath@ unset.
lsmDatabasePathDefaultCase :: TestTree
lsmDatabasePathDefaultCase =
  testCase "V2LSM defaults LSMDatabasePath to \"lsm\" when unset" $ do
    path <- getDataFileName "examples/lsm-mithril-export.json"
    (cfg, _) <- parseConfigurationFiles path
    expectOk $ case cliArgs [] of
      Nothing -> Just "could not build CLI arguments"
      Just cli -> case resolveConfiguration cli cfg of
        Left e -> Just ("resolve failed: " <> show e)
        Right nc -> case backendSelector (runIdentity (ledgerDbConfiguration (C.storageConfiguration nc))) of
          Just (V2LSM (Just "lsm") (Just "export-dir")) -> Nothing
          other -> Just ("unexpected backend: " <> show other)

-- | The Dijkstra genesis example decodes through this library's codec (with no
-- pinned hash, so the read succeeds without a hash check).
dijkstraGenesisDecodeCase :: TestTree
dijkstraGenesisDecodeCase =
  testCase "examples/dijkstra-genesis.json (decodes via the Dijkstra codec)" $ do
    path <- getDataFileName "examples/dijkstra-genesis.json"
    res <-
      readDijkstraGenesisFile
        ( fromJust $
            hashFromTextAsHex (T.pack "56c06ff0f668c584fc54fa3cee92dd5e121b67696924ac3b01b5aec9ecf95b78")
        )
        path
    case res of
      Left err -> assertFailure (show err)
      Right g -> () <$ evaluate (length (show g))

-- | Reading a genesis file with a wrong expected hash is rejected.
dijkstraGenesisHashMismatchCase :: TestTree
dijkstraGenesisHashMismatchCase =
  testCase "examples/dijkstra-genesis.json (wrong hash is rejected)" $ do
    path <- getDataFileName "examples/dijkstra-genesis.json"
    let wrongHash :: Hash Blake2b_256 a
        wrongHash = fromJust $ hashFromTextAsHex (T.pack (replicate 64 '0'))
    res <- readDijkstraGenesisFile wrongHash path
    expectOk $ case res of
      Left (GenesisHashMismatch{}) -> Nothing
      Left err -> Just ("expected a hash mismatch, got: " <> show err)
      Right _ -> Just "expected a hash mismatch, but the read succeeded"

-- | A @DijkstraGenesisFile@ without a @DijkstraGenesisHash@ is rejected at parse
-- time: a genesis file must come with a pinned hash.
genesisHashRequiredCase :: TestTree
genesisHashRequiredCase =
  testCase "examples/testing-dijkstra-nohash.json (genesis file requires a hash)" $ do
    res <-
      decodeData "examples/testing-dijkstra-nohash.json" ::
        IO (Either String (TestingConfiguration Maybe))
    expectOk $ case res of
      Left err
        | "DijkstraGenesisHash" `isInfixOf` err -> Nothing
        | otherwise -> Just ("rejected, but with an unexpected error: " <> err)
      Right _ -> Just "expected rejection (missing DijkstraGenesisHash), but decoding succeeded"

-- | A @DijkstraGenesisFile@ accompanied by a @DijkstraGenesisHash@ decodes.
genesisHashPresentCase :: TestTree
genesisHashPresentCase =
  decodeCase
    "examples/testing-dijkstra.json (genesis file + hash decodes)"
    ( decodeData "examples/testing-dijkstra.json" ::
        IO (Either String (TestingConfiguration Maybe))
    )

-- | The Byron genesis decodes (canonical JSON) and its hash checks out via the
-- ledger's reader. The expected hash is the real mainnet Byron genesis hash.
byronGenesisDecodeCase :: TestTree
byronGenesisDecodeCase =
  testCase "examples/mainnet-byron-genesis.json (decodes + hash-checks via the ledger)" $ do
    path <- getDataFileName "examples/mainnet-byron-genesis.json"
    case hashFromTextAsHex (T.pack "5f20df933584822601f9e3f8c024eb5eb252fe8cefb24d1317dc3d432e940ebb") of
      Nothing -> assertFailure "could not parse the expected Byron genesis hash"
      Just expected -> do
        res <- readByronGenesisConfig RequiresNoMagic expected path
        expectOk (either (Just . ("Byron read failed: " <>)) (const Nothing) res)

-- | A genesis codec must agree with the ledger's own instances, both ways:
-- decoding the example with our codec yields the same value the ledger's
-- 'FromJSON' does, and re-encoding it with our codec yields the same JSON the
-- ledger's 'ToJSON' does.
roundTripCase :: (FromJSON a, ToJSON a, Eq a) => String -> FilePath -> JSONCodec a -> TestTree
roundTripCase label file genesisCodec =
  testCase label $ do
    res <- decodeData file :: IO (Either String Value)
    expectOk $ case res of
      Left err -> Just ("could not read example: " <> err)
      Right value ->
        case (parseEither parseJSON value, parseEither (parseJSONVia genesisCodec) value) of
          (Left err, _) -> Just ("ledger decode failed: " <> err)
          (_, Left err) -> Just ("our codec decode failed: " <> err)
          (Right ref, Right mine)
            | ref /= mine -> Just "decoded value differs from the ledger's decode"
            | toJSON ref /= toJSONVia genesisCodec mine ->
                Just "re-encoded JSON differs from the ledger's encode"
            | otherwise -> Nothing

-- | The committed schemas under @schemas/@ (the whole configuration and one per
-- component) must match the schema derived from the codecs, so the documented
-- schema cannot drift from the parsers. Regenerate them with @scripts/gen-schemas.sh@.
schemaTests :: IO TestTree
schemaTests = do
  defs <- componentDefaults
  pure $
    testGroup "schemas" $
      schemaTest "schemas/config.schema.json" (splitConfigSchemaWithDefaults defs)
        : schemaTest
          "schemas/config.legacy-one-file.schema.json"
          (legacyOneFileConfigSchemaWithDefaults defs)
        : [ schemaTest ("schemas/" <> T.unpack name <> ".schema.json") schema
          | (name, schema) <- configurationSchemasWithDefaults defs <> genesisSchemas
          ]

-- | Assert that a committed schema file equals the given derived schema.
schemaTest :: FilePath -> Value -> TestTree
schemaTest path expected =
  testCase path $ do
    full <- getDataFileName path
    res <- eitherDecodeFileStrict' full :: IO (Either String Value)
    case res of
      Left err -> assertFailure ("could not read " <> path <> ": " <> err)
      Right committed ->
        assertBool
          (path <> " is out of date; regenerate with scripts/gen-schemas.sh")
          (committed == expected)
