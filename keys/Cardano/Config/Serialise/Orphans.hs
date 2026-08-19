{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Orphan instances the key layer needs and that no upstream package provides.
--
-- They belong here, below every module that uses them, so that exactly one copy
-- exists: a second definition elsewhere in the dependency graph would be a
-- duplicate-instance error.
module Cardano.Config.Serialise.Orphans () where

import Cardano.Binary (DecoderError (..), FromCBOR (..), ToCBOR (..))
import Cardano.Binary.FixedSizeCodec qualified as Crypto
import Cardano.Ledger.Core (fromEraCBOR, toEraCBOR)
import Cardano.Ledger.Keys qualified as Ledger
import Cardano.Ledger.Shelley (ShelleyEra)
import Cardano.Protocol.Crypto (StandardCrypto)
import Cardano.Protocol.TPraos.OCert qualified as Ledger
import Codec.CBOR.Read qualified as CBOR
import Data.Data (Data)
import Data.Typeable (Typeable)

-- 'TextEnvelopeError' embeds a 'DecoderError' and derives 'Data'; neither
-- @cardano-binary@ nor @cborg@ provides that instance.
deriving instance Data DecoderError

deriving instance Data CBOR.DeserialiseFailure

-- TODO: drop these and use EncCBOR/DecCBOR
instance ToCBOR (Ledger.OCert StandardCrypto) where
  toCBOR = toEraCBOR @ShelleyEra

instance FromCBOR (Ledger.OCert StandardCrypto) where
  fromCBOR = fromEraCBOR @ShelleyEra

instance Typeable kd => ToCBOR (Ledger.VKey kd) where
  toCBOR (Ledger.VKey vk) = Crypto.encodeFixedSized vk

instance Typeable kd => FromCBOR (Ledger.VKey kd) where
  fromCBOR = Ledger.VKey <$> Crypto.decodeFixedSized
