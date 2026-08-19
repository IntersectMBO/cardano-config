{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Praos consensus key types and their 'Key' class instances
module Cardano.Config.Key.Praos
  ( -- * Key types
    KesKey
  , VrfKey

    -- * Data family instances
  , AsType (..)
  , Hash (..)
  , VerificationKey (..)
  , SigningKey (..)

    -- * Signing
  , signArbitraryBytesKes
  )
where

import Cardano.Binary.FixedSizeCodec qualified as Crypto
import Cardano.Config.Key.Class
import Cardano.Config.Key.HasTypeProxy
import Cardano.Config.Key.Hash
import Cardano.Config.Serialise.Cbor
import Cardano.Config.Serialise.Raw
import Cardano.Config.Serialise.TextEnvelope
import Cardano.Config.Serialise.Using
import Cardano.Crypto.DSIGN.Class qualified as Crypto
import Cardano.Crypto.Hash.Class qualified as Crypto
import Cardano.Crypto.KES.Class qualified as Crypto
import Cardano.Crypto.VRF.Class qualified as Crypto
import Cardano.Ledger.Hashes (HASH)
import Cardano.Protocol.Crypto (KES, StandardCrypto, VRF)
import Data.ByteString (ByteString)
import Data.Either.Combinators (maybeToRight)
import Data.String (IsString (..))
import Prettyprinter (Pretty)

--
-- KES keys
--

data KesKey

instance HasTypeProxy KesKey where
  data AsType KesKey = AsKesKey
  proxyToAsType _ = AsKesKey

instance Key KesKey where
  newtype VerificationKey KesKey
    = KesVerificationKey (Crypto.VerKeyKES (KES StandardCrypto))
    deriving stock Eq
    deriving (Show, Pretty) via UsingRawBytesHex (VerificationKey KesKey)
    deriving newtype (ToCBOR, FromCBOR)
    deriving anyclass SerialiseAsCBOR

  newtype SigningKey KesKey
    = KesSigningKey (Crypto.UnsoundPureSignKeyKES (KES StandardCrypto))
    deriving (Show, Pretty) via UsingRawBytesHex (SigningKey KesKey)
    deriving newtype (ToCBOR, FromCBOR)
    deriving anyclass SerialiseAsCBOR

  -- This loses the mlock safety of the seed, since it starts from a normal in-memory seed.
  deterministicSigningKey :: AsType KesKey -> Crypto.Seed -> SigningKey KesKey
  deterministicSigningKey AsKesKey =
    KesSigningKey . Crypto.unsoundPureGenKeyKES

  deterministicSigningKeySeedSize :: AsType KesKey -> Word
  deterministicSigningKeySeedSize AsKesKey =
    Crypto.seedSizeKES proxy
   where
    proxy :: Proxy (KES StandardCrypto)
    proxy = Proxy

  getVerificationKey :: SigningKey KesKey -> VerificationKey KesKey
  getVerificationKey (KesSigningKey sk) =
    KesVerificationKey (Crypto.unsoundPureDeriveVerKeyKES sk)

  verificationKeyHash :: VerificationKey KesKey -> Hash KesKey
  verificationKeyHash (KesVerificationKey vkey) =
    KesKeyHash (Crypto.hashVerKeyKES vkey)

instance SerialiseAsRawBytes (VerificationKey KesKey) where
  serialiseToRawBytes (KesVerificationKey vk) =
    Crypto.rawEncodeFixedSized vk

  deserialiseFromRawBytes (AsVerificationKey AsKesKey) bs =
    maybeToRight (SerialiseAsRawBytesError "Unable to deserialise VerificationKey KesKey") $
      KesVerificationKey <$> Crypto.rawDecodeFixedSized bs

instance SerialiseAsRawBytes (SigningKey KesKey) where
  serialiseToRawBytes (KesSigningKey sk) =
    Crypto.rawEncodeFixedSized sk

  deserialiseFromRawBytes (AsSigningKey AsKesKey) bs =
    maybeToRight (SerialiseAsRawBytesError "Unable to deserialise SigningKey KesKey") $
      KesSigningKey <$> Crypto.rawDecodeFixedSized bs

newtype instance Hash KesKey
  = KesKeyHash
      ( Crypto.Hash
          HASH
          (Crypto.VerKeyKES (KES StandardCrypto))
      )
  deriving stock (Eq, Ord)
  deriving (Show, Pretty) via UsingRawBytesHex (Hash KesKey)
  deriving (ToCBOR, FromCBOR) via UsingRawBytes (Hash KesKey)
  deriving anyclass SerialiseAsCBOR

instance SerialiseAsRawBytes (Hash KesKey) where
  serialiseToRawBytes (KesKeyHash vkh) =
    Crypto.hashToBytes vkh

  deserialiseFromRawBytes (AsHash AsKesKey) bs =
    maybeToRight (SerialiseAsRawBytesError "Unable to deserialise Hash KesKey") $
      KesKeyHash <$> Crypto.hashFromBytes bs

instance HasTextEnvelope (VerificationKey KesKey) where
  textEnvelopeType _ =
    "KesVerificationKey_"
      <> fromString (Crypto.algorithmNameKES proxy)
   where
    proxy :: Proxy (KES StandardCrypto)
    proxy = Proxy

instance HasTextEnvelope (SigningKey KesKey) where
  textEnvelopeType _ =
    "KesSigningKey_"
      <> fromString (Crypto.algorithmNameKES proxy)
   where
    proxy :: Proxy (KES StandardCrypto)
    proxy = Proxy

signArbitraryBytesKes ::
  SigningKey KesKey ->
  -- | Desired Kes period
  Crypto.Period ->
  -- | Message to sign
  ByteString ->
  Crypto.SignedKES (KES StandardCrypto) ByteString
signArbitraryBytesKes (KesSigningKey kesKey) period message =
  Crypto.unsoundPureSignedKES @(KES StandardCrypto) () period message kesKey

--
-- VRF keys
--

data VrfKey

instance HasTypeProxy VrfKey where
  data AsType VrfKey = AsVrfKey
  proxyToAsType _ = AsVrfKey

instance Key VrfKey where
  newtype VerificationKey VrfKey
    = VrfVerificationKey (Crypto.VerKeyVRF (VRF StandardCrypto))
    deriving stock Eq
    deriving (Show, Pretty) via UsingRawBytesHex (VerificationKey VrfKey)
    deriving newtype (ToCBOR, FromCBOR)
    deriving anyclass SerialiseAsCBOR

  newtype SigningKey VrfKey
    = VrfSigningKey (Crypto.SignKeyVRF (VRF StandardCrypto))
    deriving (Show, Pretty) via UsingRawBytesHex (SigningKey VrfKey)
    deriving newtype (ToCBOR, FromCBOR)
    deriving anyclass SerialiseAsCBOR

  deterministicSigningKey :: AsType VrfKey -> Crypto.Seed -> SigningKey VrfKey
  deterministicSigningKey AsVrfKey seed =
    VrfSigningKey (Crypto.genKeyVRF seed)

  deterministicSigningKeySeedSize :: AsType VrfKey -> Word
  deterministicSigningKeySeedSize AsVrfKey =
    Crypto.seedSizeVRF proxy
   where
    proxy :: Proxy (VRF StandardCrypto)
    proxy = Proxy

  getVerificationKey :: SigningKey VrfKey -> VerificationKey VrfKey
  getVerificationKey (VrfSigningKey sk) =
    VrfVerificationKey (Crypto.deriveVerKeyVRF sk)

  verificationKeyHash :: VerificationKey VrfKey -> Hash VrfKey
  verificationKeyHash (VrfVerificationKey vkey) =
    VrfKeyHash (Crypto.hashVerKeyVRF vkey)

instance SerialiseAsRawBytes (VerificationKey VrfKey) where
  serialiseToRawBytes (VrfVerificationKey vk) =
    Crypto.rawEncodeFixedSized vk

  deserialiseFromRawBytes (AsVerificationKey AsVrfKey) bs =
    maybeToRight (SerialiseAsRawBytesError "Unable to deserialise VerificationKey VrfKey") $
      VrfVerificationKey <$> Crypto.rawDecodeFixedSized bs

instance SerialiseAsRawBytes (SigningKey VrfKey) where
  serialiseToRawBytes (VrfSigningKey sk) =
    Crypto.rawEncodeFixedSized sk

  deserialiseFromRawBytes (AsSigningKey AsVrfKey) bs =
    maybeToRight (SerialiseAsRawBytesError "Unable to deserialise SigningKey VrfKey") $
      VrfSigningKey <$> Crypto.rawDecodeFixedSized bs

newtype instance Hash VrfKey
  = VrfKeyHash
  { unVrfKeyHash :: Crypto.Hash HASH (Crypto.VerKeyVRF (VRF StandardCrypto))
  }
  deriving stock (Eq, Ord)
  deriving (Show, Pretty) via UsingRawBytesHex (Hash VrfKey)
  deriving (ToCBOR, FromCBOR) via UsingRawBytes (Hash VrfKey)
  deriving anyclass SerialiseAsCBOR

instance SerialiseAsRawBytes (Hash VrfKey) where
  serialiseToRawBytes (VrfKeyHash vkh) =
    Crypto.hashToBytes vkh

  deserialiseFromRawBytes (AsHash AsVrfKey) bs =
    maybeToRight (SerialiseAsRawBytesError "Unable to deserialise Hash VrfKey") $
      VrfKeyHash <$> Crypto.hashFromBytes bs

instance HasTextEnvelope (VerificationKey VrfKey) where
  textEnvelopeType _ = "VrfVerificationKey_" <> fromString (Crypto.algorithmNameVRF proxy)
   where
    proxy :: Proxy (VRF StandardCrypto)
    proxy = Proxy

instance HasTextEnvelope (SigningKey VrfKey) where
  textEnvelopeType _ = "VrfSigningKey_" <> fromString (Crypto.algorithmNameVRF proxy)
   where
    proxy :: Proxy (VRF StandardCrypto)
    proxy = Proxy
