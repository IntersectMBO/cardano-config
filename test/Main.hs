-- | Golden-ish tests: every example configuration must parse through the
-- autodocodec-derived parsers (and the full file pipeline). This is the most
-- reliable validation we have, since the parser shares its codec with the
-- schema.
--
-- The @examples/@ and @schemas/@ fixtures are resolved through
-- 'getDataFileName' (they are packaged as @data-files@), so the tests do not
-- depend on the current working directory and work under @cabal test@, Nix and
-- a source distribution alike.
module Main (main) where

import Cardano.Configuration (resolveConfiguration)
import Cardano.Configuration.CliArgs (parseCliArgs)
import Cardano.Configuration.File
import Cardano.Configuration.Genesis (GenesisReadError (..), readDijkstraGenesisFile)
import Cardano.Configuration.Genesis.Alonzo (alonzoGenesisCodec)
import Cardano.Configuration.Genesis.Byron (readByronGenesisConfig)
import Cardano.Configuration.Genesis.Conway (conwayGenesisCodec)
import Cardano.Configuration.Genesis.Shelley (shelleyGenesisCodec)
import Cardano.Crypto.ProtocolMagic (RequiresNetworkMagic (RequiresNoMagic))
import Cardano.Configuration.Schema (
  configurationSchemasWithDefaults,
  genesisSchemas,
  wholeConfigSchemaWithDefaults,
 )
import Cardano.Crypto.Hash (Blake2b_256, Hash, hashFromTextAsHex)
import Control.Exception (SomeException, evaluate, try)
import Autodocodec (JSONCodec, parseJSONVia, toJSONVia)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeFileStrict', parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.Functor.Identity (runIdentity)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Options.Applicative (defaultPrefs, execParserPure, getParseResult, info)
import Paths_cardano_config (getDataFileName)
import System.Exit (exitFailure)

main :: IO ()
main = do
  results <-
    sequence
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
      , listMergeCase
      , shadowWarnCase
      , shadowRejectCase
      , resolveCase
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
  schemaResults <- schemaCases
  let failed = length (filter not (results <> schemaResults))
  if failed == 0
    then putStrLn "All checks passed"
    else do
      putStrLn $ show failed <> " check(s) failed"
      exitFailure

-- | Decode a packaged data file (resolved via 'getDataFileName') through its
-- 'FromJSON' instance.
decodeData :: FromJSON a => FilePath -> IO (Either String a)
decodeData p = getDataFileName p >>= eitherDecodeFileStrict'

-- | Decode a single example via its 'FromJSON' instance, forcing the result.
decodeCase :: Show a => String -> IO (Either String a) -> IO Bool
decodeCase label act = do
  res <- act
  case res of
    Left err -> report label (Just err)
    Right v -> do
      _ <- evaluate (length (show v))
      report label Nothing

-- | Parse a full configuration file (exercising sub-files).
parseCase :: FilePath -> IO Bool
parseCase fp = do
  path <- getDataFileName fp
  res <- try (parseConfigurationFiles path >>= \c -> evaluate (length (show c)))
  report fp $ case res of
    Left (e :: SomeException) -> Just (show e)
    Right _ -> Nothing

-- | A section given as a list of sources is deep-merged in order, with later
-- entries overriding earlier ones (and the always-read base default beneath).
-- @network-b.json@ sets @TargetNumberOfActivePeers@ to 99, overriding the 10 in
-- @network-a.json@.
listMergeCase :: IO Bool
listMergeCase = do
  let label = "examples/split-list.json (list merge, later overrides)"
  path <- getDataFileName "examples/split-list.json"
  res <- try (parseConfigurationFiles path)
  case res of
    Left (e :: SomeException) -> report label (Just (show e))
    Right c ->
      let active = deadlineTargetOfActivePeers (runIdentity (networkConfiguration c))
       in if active == Just 99
            then report label Nothing
            else report label (Just ("expected TargetNumberOfActivePeers = 99, got " <> show active))

-- | A top-level key belonging to a component that is also supplied as its own
-- section (here a top-level @DijkstraGenesisFile@ alongside a @TestingConfig@
-- section) is shadowed. Under the default policy this only warns, so parsing
-- succeeds.
shadowWarnCase :: IO Bool
shadowWarnCase = do
  let label = "examples/shadow.json (shadowed top-level key warns, still parses)"
  path <- getDataFileName "examples/shadow.json"
  res <- try (parseConfigurationFiles path >>= \c -> evaluate (length (show c)))
  report label $ case res of
    Left (e :: SomeException) -> Just (show e)
    Right _ -> Nothing

-- | The same shadowed key is a hard error under 'RejectUnknownKeys', and the
-- error names the offending key.
shadowRejectCase :: IO Bool
shadowRejectCase = do
  let label = "examples/shadow.json (shadowed top-level key rejected under strict policy)"
  path <- getDataFileName "examples/shadow.json"
  res <- try (parseConfigurationFilesWith RejectUnknownKeys path)
  case res of
    Left (e :: SomeException)
      | "DijkstraGenesisFile" `isInfixOf` show e -> report label Nothing
      | otherwise -> report label (Just ("rejected, but with an unexpected error: " <> show e))
    Right _ -> report label (Just "expected rejection under RejectUnknownKeys, but parsing succeeded")

-- | Resolving a parsed configuration with default CLI arguments must succeed and
-- produce a complete (@Identity@) configuration, which exercises that the base
-- defaults populate every resolved field.
resolveCase :: IO Bool
resolveCase = do
  let label = "resolveConfiguration examples/fullconfig.json"
  path <- getDataFileName "examples/fullconfig.json"
  cfg <- parseConfigurationFiles path
  case getParseResult (execParserPure defaultPrefs (info parseCliArgs mempty) []) of
    Nothing -> report label (Just "could not build default CLI arguments")
    Just cli -> case resolveConfiguration cli cfg of
      Left err -> report label (Just (show err))
      Right nc -> evaluate (length (show nc)) >> report label Nothing

-- | The Dijkstra genesis example decodes through this library's codec (with no
-- pinned hash, so the read succeeds without a hash check).
dijkstraGenesisDecodeCase :: IO Bool
dijkstraGenesisDecodeCase = do
  let label = "examples/dijkstra-genesis.json (decodes via the Dijkstra codec)"
  path <- getDataFileName "examples/dijkstra-genesis.json"
  res <- readDijkstraGenesisFile Nothing path
  case res of
    Left err -> report label (Just (show err))
    Right g -> evaluate (length (show g)) >> report label Nothing

-- | Reading a genesis file with a wrong expected hash is rejected.
dijkstraGenesisHashMismatchCase :: IO Bool
dijkstraGenesisHashMismatchCase = do
  let label = "examples/dijkstra-genesis.json (wrong hash is rejected)"
  path <- getDataFileName "examples/dijkstra-genesis.json"
  let wrongHash :: Maybe (Hash Blake2b_256 a)
      wrongHash = hashFromTextAsHex (T.pack (replicate 64 '0'))
  res <- readDijkstraGenesisFile wrongHash path
  report label $ case res of
    Left (GenesisHashMismatch{}) -> Nothing
    Left err -> Just ("expected a hash mismatch, got: " <> show err)
    Right _ -> Just "expected a hash mismatch, but the read succeeded"

-- | A @DijkstraGenesisFile@ without a @DijkstraGenesisHash@ is rejected at parse
-- time: a genesis file must come with a pinned hash.
genesisHashRequiredCase :: IO Bool
genesisHashRequiredCase = do
  let label = "examples/testing-dijkstra-nohash.json (genesis file requires a hash)"
  res <-
    decodeData "examples/testing-dijkstra-nohash.json"
      :: IO (Either String (TestingConfiguration Maybe))
  report label $ case res of
    Left err
      | "DijkstraGenesisHash" `isInfixOf` err -> Nothing
      | otherwise -> Just ("rejected, but with an unexpected error: " <> err)
    Right _ -> Just "expected rejection (missing DijkstraGenesisHash), but decoding succeeded"

-- | A @DijkstraGenesisFile@ accompanied by a @DijkstraGenesisHash@ decodes.
genesisHashPresentCase :: IO Bool
genesisHashPresentCase =
  decodeCase
    "examples/testing-dijkstra.json (genesis file + hash decodes)"
    ( decodeData "examples/testing-dijkstra.json"
        :: IO (Either String (TestingConfiguration Maybe))
    )

-- | The Byron genesis decodes (canonical JSON) and its hash checks out via the
-- ledger's reader. The expected hash is the real mainnet Byron genesis hash.
byronGenesisDecodeCase :: IO Bool
byronGenesisDecodeCase = do
  let label = "examples/mainnet-byron-genesis.json (decodes + hash-checks via the ledger)"
  path <- getDataFileName "examples/mainnet-byron-genesis.json"
  case hashFromTextAsHex (T.pack "5f20df933584822601f9e3f8c024eb5eb252fe8cefb24d1317dc3d432e940ebb") of
    Nothing -> report label (Just "could not parse the expected Byron genesis hash")
    Just expected -> do
      res <- readByronGenesisConfig RequiresNoMagic expected path
      report label (either (Just . ("Byron read failed: " <>)) (const Nothing) res)

-- | A genesis codec must agree with the ledger's own instances, both ways:
-- decoding the example with our codec yields the same value the ledger's
-- 'FromJSON' does, and re-encoding it with our codec yields the same JSON the
-- ledger's 'ToJSON' does.
roundTripCase :: (FromJSON a, ToJSON a, Eq a) => String -> FilePath -> JSONCodec a -> IO Bool
roundTripCase label file genesisCodec = do
  res <- decodeData file :: IO (Either String Value)
  case res of
    Left err -> report label (Just ("could not read example: " <> err))
    Right value ->
      case (parseEither parseJSON value, parseEither (parseJSONVia genesisCodec) value) of
        (Left err, _) -> report label (Just ("ledger decode failed: " <> err))
        (_, Left err) -> report label (Just ("our codec decode failed: " <> err))
        (Right ref, Right mine)
          | ref /= mine ->
              report label (Just "decoded value differs from the ledger's decode")
          | toJSON ref /= toJSONVia genesisCodec mine ->
              report label (Just "re-encoded JSON differs from the ledger's encode")
          | otherwise -> report label Nothing

-- | The committed schemas under @schemas/@ (the whole configuration and one per
-- component) must match the schema derived from the codecs, so the documented
-- schema cannot drift from the parsers. Regenerate them with @scripts/gen-schemas.sh@.
schemaCases :: IO [Bool]
schemaCases = do
  defs <- componentDefaults
  sequence $
    schemaFile "schemas/config.schema.json" (wholeConfigSchemaWithDefaults defs)
      : [ schemaFile ("schemas/" <> T.unpack name <> ".schema.json") schema
        | (name, schema) <- configurationSchemasWithDefaults defs <> genesisSchemas
        ]

-- | Assert that a committed schema file equals the given derived schema.
schemaFile :: FilePath -> Value -> IO Bool
schemaFile path expected = do
  let label = path <> " (matches codecs)"
  full <- getDataFileName path
  res <- eitherDecodeFileStrict' full :: IO (Either String Value)
  case res of
    Left err -> report label (Just ("could not read " <> path <> ": " <> err))
    Right committed
      | committed == expected -> report label Nothing
      | otherwise ->
          report label (Just (path <> " is out of date; regenerate with scripts/gen-schemas.sh"))

report :: String -> Maybe String -> IO Bool
report label = \case
  Nothing -> putStrLn ("PASS  " <> label) >> pure True
  Just err -> putStrLn ("FAIL  " <> label <> "\n      " <> err) >> pure False
