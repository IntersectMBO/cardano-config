{-# LANGUAGE ScopedTypeVariables #-}

-- | @deriving via@ helpers built on top of 'SerialiseAsRawBytes'
module Cardano.Config.Serialise.Using
  ( UsingRawBytes (..)
  , UsingRawBytesHex (..)
  )
where

import Cardano.Config.Key.HasTypeProxy
import Cardano.Config.Serialise.Cbor
import Cardano.Config.Serialise.Raw
import Data.Aeson (FromJSON (..), FromJSONKey (..), ToJSON (..), ToJSONKey (..))
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as B
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Typeable (tyConName, typeRep, typeRepTyCon)
import Numeric (showBin)
import Prettyprinter (Pretty (..))

-- | For use with @deriving via@, to provide 'ToCBOR' and 'FromCBOR' instances,
-- based on the 'SerialiseAsRawBytes' instance.
--
-- > deriving (ToCBOR, FromCBOR) via (UsingRawBytes Blah)
newtype UsingRawBytes a = UsingRawBytes a

instance SerialiseAsRawBytes a => ToCBOR (UsingRawBytes a) where
  toCBOR (UsingRawBytes x) = toCBOR (serialiseToRawBytes x)

instance SerialiseAsRawBytes a => FromCBOR (UsingRawBytes a) where
  fromCBOR = do
    bs <- fromCBOR
    case deserialiseFromRawBytes ttoken bs of
      Right x -> return (UsingRawBytes x)
      Left (SerialiseAsRawBytesError msg) -> fail ("cannot deserialise as a " ++ tname ++ ".  The error was: " ++ msg)
   where
    ttoken = proxyToAsType (Proxy :: Proxy a)
    tname = (tyConName . typeRepTyCon . typeRep) (Proxy :: Proxy a)

-- | Prints the representation in binary format, quoted
instance SerialiseAsRawBytes a => Show (UsingRawBytes a) where
  showsPrec _ (UsingRawBytes x) = showChar '"' . mconcat (map showBin . B.unpack $ serialiseToRawBytes x) . showChar '"'

-- | For use with @deriving via@, to provide instances for any\/all of 'Show',
-- 'ToJSON', 'FromJSON', 'ToJSONKey', FromJSONKey' using a hex
-- encoding, based on the 'SerialiseAsRawBytes' instance.
--
-- > deriving (Show, Pretty) via (UsingRawBytesHex Blah)
-- > deriving (ToJSON, FromJSON) via (UsingRawBytesHex Blah)
-- > deriving (ToJSONKey, FromJSONKey) via (UsingRawBytesHex Blah)
newtype UsingRawBytesHex a = UsingRawBytesHex a

-- | Quotes the representation
instance SerialiseAsRawBytes a => Show (UsingRawBytesHex a) where
  show (UsingRawBytesHex x) = show $ serialiseToRawBytesHex x

instance SerialiseAsRawBytes a => Pretty (UsingRawBytesHex a) where
  pretty (UsingRawBytesHex a) = pretty $ serialiseToRawBytesHexText a

instance SerialiseAsRawBytes a => ToJSON (UsingRawBytesHex a) where
  toJSON (UsingRawBytesHex x) = toJSON (serialiseToRawBytesHexText x)

instance SerialiseAsRawBytes a => FromJSON (UsingRawBytesHex a) where
  parseJSON =
    fmap (fmap UsingRawBytesHex) . Aeson.withText tname $
      failRawBytesHex . deserialiseFromRawBytesHex . Text.encodeUtf8
   where
    tname = (tyConName . typeRepTyCon . typeRep) (Proxy :: Proxy a)

instance SerialiseAsRawBytes a => ToJSONKey (UsingRawBytesHex a) where
  toJSONKey =
    Aeson.toJSONKeyText $ \(UsingRawBytesHex x) -> serialiseToRawBytesHexText x

instance SerialiseAsRawBytes a => FromJSONKey (UsingRawBytesHex a) where
  fromJSONKey =
    fmap UsingRawBytesHex . Aeson.FromJSONKeyTextParser $
      failRawBytesHex . deserialiseFromRawBytesHex . Text.encodeUtf8

-- | 'fail' in the parser monad with a rendered 'RawBytesHexError'.
failRawBytesHex :: MonadFail m => Either RawBytesHexError a -> m a
failRawBytesHex = either (fail . Text.unpack . renderRawBytesHexError) pure
