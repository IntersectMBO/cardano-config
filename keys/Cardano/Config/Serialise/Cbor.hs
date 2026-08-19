{-# LANGUAGE DefaultSignatures #-}

-- | CBOR serialisation
module Cardano.Config.Serialise.Cbor
  ( SerialiseAsCBOR (..)
  , FromCBOR (..)
  , ToCBOR (..)
  , CBOR.DecoderError (..)
  )
where

import Cardano.Binary (FromCBOR, ToCBOR)
import Cardano.Binary qualified as CBOR
import Cardano.Config.Key.HasTypeProxy
import Data.ByteString (ByteString)

class HasTypeProxy a => SerialiseAsCBOR a where
  serialiseToCBOR :: a -> ByteString
  deserialiseFromCBOR :: AsType a -> ByteString -> Either CBOR.DecoderError a

  default serialiseToCBOR :: ToCBOR a => a -> ByteString
  serialiseToCBOR = CBOR.serialize'

  default deserialiseFromCBOR ::
    FromCBOR a =>
    AsType a ->
    ByteString ->
    Either CBOR.DecoderError a
  deserialiseFromCBOR _proxy = CBOR.decodeFull'
