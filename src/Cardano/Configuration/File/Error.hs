-- | The error type reported when reading or parsing the configuration files.
module Cardano.Configuration.File.Error
  ( ConfigurationParsingError (..)
  ) where

import Control.Exception (Exception)
import Data.Aeson.Types (JSONPath, formatError)

-- | An error encountered while reading or parsing the configuration. It records
-- enough context to point the user at the offending file, section and location.
data ConfigurationParsingError = ConfigurationParsingError
  { errFile :: Maybe FilePath
  -- ^ The referenced sub-file the failure occurred in, if any (otherwise the
  --     failure was in the main configuration file).
  , errSection :: Maybe String
  -- ^ The top-level configuration section being parsed (e.g. @"StorageConfig"@).
  , errPath :: JSONPath
  -- ^ The path to the offending value within the JSON\/YAML document.
  , errMessage :: String
  -- ^ The underlying error message.
  }
  deriving Eq

instance Exception ConfigurationParsingError

instance Show ConfigurationParsingError where
  show ConfigurationParsingError{errFile, errSection, errPath, errMessage} =
    mconcat
      [ "Error parsing the cardano-node configuration"
      , maybe "" (\s -> " (section " <> show s <> ")") errSection
      , maybe " in the main configuration file" (\f -> " in " <> f) errFile
      , ":\n  "
      , formatError errPath errMessage
      ]
