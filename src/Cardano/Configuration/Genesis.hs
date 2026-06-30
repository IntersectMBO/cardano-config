-- | Reading and decoding the era genesis files referenced by a node
-- configuration. The genesis JSON is decoded with this library's own
-- @autodocodec@ codecs (see "Cardano.Configuration.Genesis.Dijkstra"), and the
-- file hash is checked exactly as the node does: a @Blake2b_256@ hash of the raw
-- file bytes, compared against the optional expected hash from the configuration.
--
-- Only the Dijkstra (experimental) era is resolved here so far; the other eras
-- will follow the same shape.
module Cardano.Configuration.Genesis
  ( -- * Errors
    GenesisReadError (..)
  , genesisErrorFile

    -- * Reading genesis files
  , readGenesisFileWith
  , readDijkstraGenesisFile

    -- * Resolving the configuration's genesis references
  , resolveExperimentalGenesis
  ) where

import Autodocodec (JSONCodec, parseJSONVia)
import Cardano.Configuration.File.Protocol (Hashed (..))
import Cardano.Configuration.Genesis.Dijkstra (dijkstraGenesisCodec)
import Cardano.Crypto.Hash (Blake2b_256, Hash, hashWith)
import Cardano.Ledger.Dijkstra.Genesis (DijkstraGenesis)
import Control.Exception (IOException, try)
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import System.FilePath ((</>))

-- | A failure while reading, hash-checking or decoding a genesis file.
data GenesisReadError
  = -- | The file could not be read.
    GenesisFileReadError FilePath IOException
  | -- | The file's @Blake2b_256@ hash did not match the expected hash from the
    -- configuration (expected, then actual).
    GenesisHashMismatch
      FilePath
      (Hash Blake2b_256 ByteString)
      (Hash Blake2b_256 ByteString)
  | -- | The file's contents could not be decoded into the era genesis.
    GenesisDecodeError FilePath String
  deriving Show

-- | The path of the genesis file the error concerns.
genesisErrorFile :: GenesisReadError -> Maybe FilePath
genesisErrorFile = \case
  GenesisFileReadError fp _ -> Just fp
  GenesisHashMismatch fp _ _ -> Just fp
  GenesisDecodeError fp _ -> Just fp

-- | Read a genesis file, check its hash and decode it with the given codec.
--
-- The hash is computed over the raw file bytes (matching the node), so the file
-- is read strictly and hashed before decoding.
readGenesisFileWith ::
  -- | The codec to decode the genesis with.
  JSONCodec a ->
  -- | The expected file hash, if the configuration pinned one.
  Hash Blake2b_256 ByteString ->
  -- | The file to read.
  FilePath ->
  IO (Either GenesisReadError a)
readGenesisFileWith genesisCodec expected fp = do
  result <- try (BS.readFile fp)
  pure $ case result of
    Left e -> Left (GenesisFileReadError fp e)
    Right bytes ->
      let actual = hashWith id bytes
       in if expected /= actual
            then Left (GenesisHashMismatch fp expected actual)
            else case Aeson.eitherDecodeStrict' bytes of
              Left err -> Left (GenesisDecodeError fp err)
              Right value ->
                case parseEither (parseJSONVia genesisCodec) value of
                  Left err -> Left (GenesisDecodeError fp err)
                  Right a -> Right a

-- | Read and decode a Dijkstra-era genesis file.
readDijkstraGenesisFile ::
  Hash Blake2b_256 ByteString ->
  FilePath ->
  IO (Either GenesisReadError DijkstraGenesis)
readDijkstraGenesisFile = readGenesisFileWith dijkstraGenesisCodec

-- | Resolve the experimental (Dijkstra) genesis referenced by the testing
-- configuration: read and decode it if present, resolving its path relative to
-- the directory the main configuration file lives in.
resolveExperimentalGenesis ::
  -- | The directory the main configuration file lives in.
  FilePath ->
  -- | The @DijkstraGenesisFile@ reference from the testing configuration.
  Maybe (Hashed FilePath) ->
  IO (Either GenesisReadError (Maybe DijkstraGenesis))
resolveExperimentalGenesis _ Nothing = pure (Right Nothing)
resolveExperimentalGenesis root (Just (Hashed file mHash)) =
  fmap (fmap Just) (readDijkstraGenesisFile mHash (root </> file))
