{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}

-- | Operational certificates
--
-- An operational certificate is a stake pool cold key's signed statement that
-- one particular KES key may forge on its behalf; 'getHotKey' recovers that key.
--
-- Decoding only. Issuing a certificate needs addresses, protocol parameters and
-- transaction signing, none of which this component depends on.
module Cardano.Config.Key.OperationalCertificate
  ( OperationalCertificate (..)
  , OperationalCertificateIssueCounter (..)
  , Shelley.KESPeriod (..)
  , getHotKey
  , getKesPeriod
  , getOpCertCount

    -- * Data family instances
  , AsType (..)
  )
where

import Cardano.Config.Key.Class
import Cardano.Config.Key.HasTypeProxy
import Cardano.Config.Key.Praos
import Cardano.Config.Key.Shelley
import Cardano.Config.Serialise.Cbor
import Cardano.Config.Serialise.Orphans ()
import Cardano.Config.Serialise.TextEnvelope
import Cardano.Protocol.Crypto (StandardCrypto)
import Cardano.Protocol.TPraos.OCert qualified as Shelley
import Data.Word

-- ----------------------------------------------------------------------------
-- Operational certificates
--

data OperationalCertificate
  = OperationalCertificate
      !(Shelley.OCert StandardCrypto)
      !(VerificationKey StakePoolKey)
  deriving (Eq, Show)
  deriving anyclass SerialiseAsCBOR

data OperationalCertificateIssueCounter
  = OperationalCertificateIssueCounter
  { opCertIssueCount :: !Word64
  , opCertIssueColdKey :: !(VerificationKey StakePoolKey) -- For consistency checking
  }
  deriving (Eq, Show)
  deriving anyclass SerialiseAsCBOR

instance ToCBOR OperationalCertificate where
  toCBOR (OperationalCertificate ocert vkey) =
    toCBOR (ocert, vkey)

instance FromCBOR OperationalCertificate where
  fromCBOR = do
    (ocert, vkey) <- fromCBOR
    return (OperationalCertificate ocert vkey)

instance ToCBOR OperationalCertificateIssueCounter where
  toCBOR (OperationalCertificateIssueCounter counter vkey) =
    toCBOR (counter, vkey)

instance FromCBOR OperationalCertificateIssueCounter where
  fromCBOR = do
    (counter, vkey) <- fromCBOR
    return (OperationalCertificateIssueCounter counter vkey)

instance HasTypeProxy OperationalCertificate where
  data AsType OperationalCertificate = AsOperationalCertificate
  proxyToAsType _ = AsOperationalCertificate

instance HasTypeProxy OperationalCertificateIssueCounter where
  data AsType OperationalCertificateIssueCounter = AsOperationalCertificateIssueCounter
  proxyToAsType _ = AsOperationalCertificateIssueCounter

instance HasTextEnvelope OperationalCertificate where
  textEnvelopeType _ = "NodeOperationalCertificate"

instance HasTextEnvelope OperationalCertificateIssueCounter where
  textEnvelopeType _ = "NodeOperationalCertificateIssueCounter"

getHotKey :: OperationalCertificate -> VerificationKey KesKey
getHotKey (OperationalCertificate cert _) = KesVerificationKey $ Shelley.ocertVkHot cert

getKesPeriod :: OperationalCertificate -> Word
getKesPeriod (OperationalCertificate cert _) = Shelley.unKESPeriod $ Shelley.ocertKESPeriod cert

getOpCertCount :: OperationalCertificate -> Word64
getOpCertCount (OperationalCertificate cert _) = Shelley.ocertN cert
