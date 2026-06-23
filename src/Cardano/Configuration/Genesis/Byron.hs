-- | Reading the Byron-era genesis. Byron genesis files are canonical JSON (not
-- the @aeson@ JSON used by the later eras) and the genesis hash is computed over
-- the canonical-JSON rendering, so we reuse the ledger's 'mkConfigFromFile',
-- which reads, hashes and checks the file and builds a 'Config'.
module Cardano.Configuration.Genesis.Byron (
  ByronGenesisConfig,
  readByronGenesisConfig,
) where

import Cardano.Chain.Genesis (Config, mkConfigFromFile)
import Cardano.Crypto.Hash (Blake2b_256, Hash, hashToBytes)
import qualified Cardano.Crypto.Hashing as Byron
import Cardano.Crypto.ProtocolMagic (RequiresNetworkMagic)
import qualified Cardano.Crypto.Raw as Byron
import Control.Monad.Trans.Except (runExceptT)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)

-- | The parsed Byron genesis (data, hash, network-magic requirement and UTxO
-- configuration), as the ledger represents it.
type ByronGenesisConfig = Config

-- | Read, hash-check and decode a Byron genesis file into a 'Config'.
--
-- The expected hash is the @Blake2b_256@ hash from the configuration; Byron
-- represents the same hash as a @'Byron.Hash' 'Byron.Raw'@, so we rebuild it
-- from the raw bytes.
readByronGenesisConfig ::
  -- | Whether the Byron network magic is required.
  RequiresNetworkMagic ->
  -- | The expected genesis hash.
  Hash Blake2b_256 ByteString ->
  -- | The genesis file.
  FilePath ->
  IO (Either String ByronGenesisConfig)
readByronGenesisConfig rnm expected fp = do
  let expectedRaw :: Byron.Hash Byron.Raw
      expectedRaw = Byron.unsafeAbstractHashFromBytes (hashToBytes expected)
  first show <$> runExceptT (mkConfigFromFile rnm fp expectedRaw)
