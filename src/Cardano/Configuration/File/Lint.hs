-- | Linting of the top-level configuration keys: warning on (or rejecting)
-- unrecognised keys and keys shadowed by a component supplied as its own section.
-- This is the only part of the configuration-file handling that depends on the
-- schema (for the set of recognised keys and the per-component key listing).
module Cardano.Configuration.File.Lint (
  UnknownKeyPolicy (..),
  checkUnknownKeys,
  checkShadowedKeys,
) where

import Cardano.Configuration.File.Error (ConfigurationParsingError (..))
import Cardano.Configuration.Schema (componentPropertyNames, recognisedKeys)
import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (intercalate)
import qualified Data.Text as T
import System.IO (hPutStrLn, stderr)

-- | What to do when the configuration contains keys that none of the parsers
-- recognise (typically a typo).
data UnknownKeyPolicy
  = -- | Emit a warning to @stderr@ and carry on (the default).
    WarnUnknownKeys
  | -- | Reject the configuration with a 'ConfigurationParsingError'.
    RejectUnknownKeys
  deriving (Eq, Show)

-- | Check the top-level configuration keys against the recognised ones, warning
-- on (or, under 'RejectUnknownKeys', rejecting) any that are unrecognised.
checkUnknownKeys :: UnknownKeyPolicy -> FilePath -> Value -> IO ()
checkUnknownKeys policy cfgFile value =
  case value of
    Object o -> do
      let unknown = [K.toString k | k <- KM.keys o, K.toText k `notElem` recognisedKeys]
      unless (null unknown) $ do
        let msg = "unrecognised configuration key(s): " <> intercalate ", " unknown
        case policy of
          RejectUnknownKeys -> throwIO $ ConfigurationParsingError (Just cfgFile) Nothing [] msg
          WarnUnknownKeys -> hPutStrLn stderr ("Warning: " <> msg <> " (ignored)")
    _ -> pure ()

-- | Detect top-level keys shadowed by a component supplied as its own section:
-- when a section key (e.g. @Testing@) is present, that component's keys are read
-- from the section, so any sibling top-level key belonging to the same component
-- (e.g. a top-level @DijkstraGenesisFile@) is silently ignored. Such a key is
-- almost certainly a mistake, so warn (or, under 'RejectUnknownKeys', reject).
--
-- This looks only at the keys the user wrote in this object; the per-component
-- base defaults are merged separately inside 'Cardano.Configuration.File.Merge.parseSection'
-- and never appear here, so they cannot trigger it.
checkShadowedKeys :: UnknownKeyPolicy -> FilePath -> Value -> IO ()
checkShadowedKeys policy cfgFile value =
  case value of
    Object o -> do
      let present = map K.toText (KM.keys o)
          shadowed =
            [ (section, key)
            | (section, keys) <- componentPropertyNames
            , section `elem` present
            , key <- keys
            , key `elem` present
            ]
      unless (null shadowed) $ do
        let describe (section, key) = T.unpack key <> " (shadowed by the " <> T.unpack section <> " section)"
            msg =
              "top-level configuration key(s) ignored because their component is given as a separate section: "
                <> intercalate ", " (map describe shadowed)
        case policy of
          RejectUnknownKeys -> throwIO $ ConfigurationParsingError (Just cfgFile) Nothing [] msg
          WarnUnknownKeys -> hPutStrLn stderr ("Warning: " <> msg <> " (ignored)")
    _ -> pure ()
