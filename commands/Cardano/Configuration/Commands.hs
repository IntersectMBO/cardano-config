-- | The three @cardano-config@ subcommands, packaged for reuse.
--
-- This module exposes the machinery behind the @cardano-config@ executable
-- (@resolve@, @schema@ and @migrate@) so that another tool — notably
-- @cardano-node@ — can splice the same commands into its own
-- @optparse-applicative@ command tree, instead of re-implementing them.
--
-- For each command there are three layers, from most to least assembled:
--
--   * 'configCommands' (and the per-command 'resolveCommand' \/ 'schemaCommand'
--     \/ 'migrateCommand') are @'Mod' 'CommandFields' ('IO' ())@ values ready to
--     drop into an 'hsubparser'. Combine them with your own commands and run the
--     resulting @'IO' ()@:
--
--     @
--     main = join $ execParser $ info
--       (hsubparser (configCommands <> myCommands) '<**>' helper) mempty
--     @
--
--   * The @*OptionsParser@ parsers and @run*Command@ runners are the pieces, if
--     you want your own command names, descriptions or nesting.
--
--   * The @*Options@ types are the parsed arguments, if you build the parser
--     yourself.
--
-- The runners write to @stdout@\/@stderr@ and, on failure, print a message and
-- exit the process — they are terminal command actions, just as in the
-- executable.
module Cardano.Configuration.Commands
  ( -- * All commands
    configCommands

    -- * Resolve
  , ResolveOptions (..)
  , GenesisRendering (..)
  , resolveOptionsParser
  , runResolveCommand
  , resolveCommand

    -- * Schema
  , ConfigForm (..)
  , schemaOptionsParser
  , runSchemaCommand
  , schemaCommand
  , schemaValidationHelp

    -- * Migrate
  , MigrateOptions (..)
  , migrateOptionsParser
  , runMigrateCommand
  , migrateCommand
  ) where

import Cardano.Configuration (parseConfigurationFiles, renderConfigWarning, resolveConfiguration)
import Cardano.Configuration.CliArgs (CliArgs, configFilePath, parseCliArgs)
import Cardano.Configuration.File (componentDefaults)
import Cardano.Configuration.File.Merge (declaredFormatVersion, decodeValueFile)
import Cardano.Configuration.File.Migrate (migrate, renderMigrationError)
import Cardano.Configuration.Render (GenesisRendering (..), nodeConfigurationToJSON)
import Cardano.Configuration.Schema
  ( configSchemaWithDefaults
  , currentFormatVersion
  , legacyFlatConfigSchemaWithDefaults
  )
import Control.Exception (displayException, fromException, throwIO)
import Control.Exception.Safe (handleAny)
import Control.Monad (when)
import Data.Aeson (Value)
import Data.Aeson.Encode.Pretty (Config (..), defConfig, encodePretty')
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as L
import Data.Foldable (for_)
import Data.Yaml (decodeThrow)
import Data.Yaml.Pretty (encodePretty, setConfCompare, setConfDropNull)
import qualified Data.Yaml.Pretty as Yaml
import Options.Applicative
import Options.Applicative.Help.Pretty (Doc, pretty, vsep)
import System.Exit (ExitCode, exitFailure)
import System.IO (hPutStrLn, stderr)

-- | All three configuration subcommands, ready to drop into an 'hsubparser'.
--
-- Equivalent to @'resolveCommand' <> 'schemaCommand' <> 'migrateCommand'@; use
-- the individual values (or the parsers\/runners) if you want a different subset,
-- names or ordering.
configCommands :: Mod CommandFields (IO ())
configCommands = resolveCommand <> schemaCommand <> migrateCommand

-- Resolve ---------------------------------------------------------------------

-- | Arguments of the @resolve@ command: the node's own flags plus whether to
-- include the (large) decoded era genesis values in the output.
data ResolveOptions = ResolveOptions
  { resolveCliArgs :: CliArgs
  , resolveGeneses :: GenesisRendering
  }

-- | Parser for 'ResolveOptions' (the node CLI flags and @--with-geneses@).
resolveOptionsParser :: Parser ResolveOptions
resolveOptionsParser = ResolveOptions <$> parseCliArgs <*> withGenesesFlag

-- | The @resolve@ subcommand, as an 'hsubparser' entry.
resolveCommand :: Mod CommandFields (IO ())
resolveCommand =
  command
    "resolve"
    ( info
        (runResolveCommand <$> resolveOptionsParser)
        ( progDesc
            ( "Resolve a cardano-node configuration (defaults + configuration file + CLI flags) "
                <> "and print the complete result as YAML."
            )
        )
    )

-- | Resolve a configuration and print it as YAML.
runResolveCommand :: ResolveOptions -> IO ()
runResolveCommand (ResolveOptions cli geneses) = dieOnFailure $ do
  (file, warnings) <- parseConfigurationFiles (configFilePath cli)
  for_ warnings $ hPutStrLn stderr . ("Warning: " <>) . renderConfigWarning
  (nc, resolveWarnings) <- either throwIO pure $ resolveConfiguration cli file
  for_ resolveWarnings $ hPutStrLn stderr . ("Warning: " <>) . renderConfigWarning
  BS.putStr $ encodePretty yamlConfig (nodeConfigurationToJSON geneses nc)
 where
  -- Stable, readable output: keys sorted alphabetically, unset values omitted.
  yamlConfig = setConfDropNull True $ setConfCompare compare Yaml.defConfig

-- | The @--with-geneses@ flag of @resolve@: include the (large) decoded era
-- genesis values in the output.
withGenesesFlag :: Parser GenesisRendering
withGenesesFlag =
  flag
    OmitGeneses
    IncludeGeneses
    ( long "with-geneses"
        <> help "Include the decoded era genesis values in the output (large; off by default)."
    )

-- Schema ----------------------------------------------------------------------

-- | Which form of the whole-configuration schema to print.
data ConfigForm
  = -- | The current form: the envelope, with each component inline under its
    -- section key inside @Configuration@.
    CurrentForm
  | -- | The legacy flat form (all keys flat at the top level).
    LegacyFlatForm

-- | Parser for 'ConfigForm'.
schemaOptionsParser :: Parser ConfigForm
schemaOptionsParser =
  flag
    CurrentForm
    LegacyFlatForm
    ( long "legacy-flat"
        <> help
          ( "Dump the legacy flat schema (every key flat at the top level). "
              <> "Prefer the default schema for new configurations."
          )
    )

-- | The @schema@ subcommand, as an 'hsubparser' entry.
schemaCommand :: Mod CommandFields (IO ())
schemaCommand =
  command
    "schema"
    ( info
        (runSchemaCommand <$> schemaOptionsParser)
        ( progDesc "Print the cardano-node configuration JSON Schema."
            <> footerDoc (Just schemaValidationHelp)
        )
    )

-- | Print the configuration JSON Schema, in the requested form.
runSchemaCommand :: ConfigForm -> IO ()
runSchemaCommand form =
  dump $ case form of
    CurrentForm -> configSchemaWithDefaults componentDefaults
    LegacyFlatForm -> legacyFlatConfigSchemaWithDefaults componentDefaults

-- | How to validate a configuration against the schema, shown under
-- @cardano-config schema --help@.
schemaValidationHelp :: Doc
schemaValidationHelp = vsep (map pretty ls)
 where
  ls :: [String]
  ls =
    [ "Validate a configuration against the schema with ajv-cli (https://ajv.js.org):"
    , ""
    , "  cardano-config schema > config.schema.json"
    , "  ajv validate --spec=draft7 --strict=false -s config.schema.json -d my-config.json"
    , ""
    , "ajv reads JSON, so convert a YAML configuration to JSON first (e.g. with yq)."
    , "--strict=false lets ajv ignore the informational \"path\" format."
    ]

-- Migrate ---------------------------------------------------------------------

-- | Arguments of the @migrate@ command: the configuration file to migrate
-- (JSON or YAML), or @-@ to read from stdin.
newtype MigrateOptions = MigrateOptions {migrateConfigPath :: FilePath}

-- | Parser for 'MigrateOptions'.
migrateOptionsParser :: Parser MigrateOptions
migrateOptionsParser =
  MigrateOptions
    <$> strArgument
      (metavar "CONFIG" <> help "Configuration file to migrate (JSON or YAML), or - for stdin.")

-- | The @migrate@ subcommand, as an 'hsubparser' entry.
migrateCommand :: Mod CommandFields (IO ())
migrateCommand =
  command
    "migrate"
    ( info
        (runMigrateCommand <$> migrateOptionsParser)
        ( progDesc
            ( "Reshape a configuration into the recommended "
                <> "{ $schema, Version, MinNodeVersion, Configuration } envelope and print it as JSON. "
                <> "Preserves the values as written (no defaults are filled, no genesis files read)."
            )
        )
    )

-- | Read a configuration and print it, reshaped into the envelope at the
-- current format version, as JSON. A purely structural migration: it does not
-- resolve, default or validate, so the hint at the end points at @resolve@.
-- A path of @-@ reads the configuration from stdin (so it composes with @curl@).
runMigrateCommand :: MigrateOptions -> IO ()
runMigrateCommand (MigrateOptions path) = dieOnFailure $ do
  raw <- case path of
    "-" -> BS.getContents >>= decodeThrow
    _ -> decodeValueFile path
  -- A document written for a newer format version cannot be migrated down to
  -- this one, so say so instead of rewriting it into something it is not.
  declared <- declaredFormatVersion raw
  when (declared > currentFormatVersion) $
    die $
      "This configuration declares format version "
        <> show declared
        <> ", and this cardano-config writes version "
        <> show currentFormatVersion
        <> ". Upgrade cardano-config to migrate it."
  (migrated, warnings) <- either (die . renderMigrationError) pure (migrate raw)
  for_ warnings $ hPutStrLn stderr . ("Warning: " <>) . renderConfigWarning
  dump migrated
  hPutStrLn stderr $
    "Migrated to format version "
      <> show currentFormatVersion
      <> ". Run `cardano-config resolve --config <file>` to check that it parses."

-- Shared helpers --------------------------------------------------------------

-- | Run a command action, reporting any failure on @stderr@ and exiting with a
-- failure status. The 'ExitCode' 'die' throws passes straight through, so a
-- message 'die' has already printed is not printed a second time as
-- @ExitFailure 1@.
dieOnFailure :: IO () -> IO ()
dieOnFailure = handleAny $ \e -> case fromException e :: Maybe ExitCode of
  Just code -> throwIO code
  Nothing -> die (displayException e)

-- | Print a JSON 'Value' with sorted keys for stable output.
dump :: Value -> IO ()
dump = L.putStrLn . encodePretty' defConfig{confCompare = compare}

-- | Print a message to @stderr@ and exit with a failure status.
die :: String -> IO a
die msg = hPutStrLn stderr msg >> exitFailure
