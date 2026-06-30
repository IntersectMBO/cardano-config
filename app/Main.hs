-- | The @cardano-config@ command-line tool. It exposes three subcommands:
--
--   * @cardano-config resolve@ resolves a @cardano-node@ configuration
--     (per-component defaults, the configuration file and the CLI flags),
--     merging and resolving it exactly as a node would, and prints the complete
--     result as YAML.
--
--   * @cardano-config schema@ dumps the configuration JSON Schema (for the
--     whole configuration or a single component), derived from the same codecs.
--
--   * @cardano-config migrate@ reshapes a configuration into the recommended
--     @{ $schema, Version, MinNodeVersion, Configuration }@ envelope and prints
--     it as JSON (a purely structural migration, preserving the values).
module Main (main) where

import Cardano.Configuration (parseConfigurationFiles, renderConfigWarning, resolveConfiguration)
import Cardano.Configuration.CliArgs (CliArgs, configFilePath, parseCliArgs)
import Cardano.Configuration.File (componentDefaults)
import Cardano.Configuration.File.Merge (decodeValueFile)
import Cardano.Configuration.File.Migrate (migrate)
import Cardano.Configuration.Render (GenesisRendering (..), nodeConfigurationToJSON)
import Cardano.Configuration.Schema
  ( configurationSchemas
  , configurationSchemasWithDefaults
  , legacyOneFileConfigSchemaWithDefaults
  , splitConfigSchemaWithDefaults
  )
import Control.Exception (displayException, throwIO)
import Control.Exception.Safe (handleAny)
import Data.Aeson (Value)
import Data.Aeson.Encode.Pretty (Config (..), defConfig, encodePretty')
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as L
import Data.Foldable (for_)
import Data.List (intercalate)
import qualified Data.Text as T
import Data.Yaml (decodeThrow)
import Data.Yaml.Pretty (encodePretty, setConfCompare, setConfDropNull)
import qualified Data.Yaml.Pretty as Yaml
import Options.Applicative
import Options.Applicative.Help.Pretty (Doc, pretty, vsep)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | The top-level command selected on the command line.
data Command
  = -- | @resolve@: resolve a configuration with the given node flags, optionally
    --       including the decoded era genesis values (the @--with-geneses@ flag).
    Resolve CliArgs GenesisRendering
  | -- | @schema@: dump a JSON Schema.
    Schema SchemaCmd
  | -- | @migrate@: reshape a configuration file into the Version1 envelope.
    Migrate FilePath

-- | What the @schema@ subcommand should print.
data SchemaCmd
  = -- | List the available component names.
    SchemaList
  | -- | Dump the whole-configuration schema, in the given form.
    SchemaWhole ConfigForm
  | -- | Dump the schema for a single named component.
    SchemaComponent String

-- | Which form of the whole-configuration schema to print.
data ConfigForm
  = -- | The recommended split-file form (each component under its section key).
    SplitForm
  | -- | The legacy single-file form (all keys flat at the top level).
    LegacyOneFileForm

main :: IO ()
main = execParser opts >>= run
 where
  opts =
    info
      (commandParser <**> helper)
      ( fullDesc
          <> progDesc "Parse, resolve and document the cardano-node configuration."
      )

-- | The full command-line parser: a subcommand tree.
commandParser :: Parser Command
commandParser =
  hsubparser
    ( command
        "resolve"
        ( info
            (Resolve <$> parseCliArgs <*> withGenesesFlag)
            ( progDesc
                ( "Resolve a cardano-node configuration (defaults + configuration file + CLI flags) "
                    <> "and print the complete result as YAML."
                )
            )
        )
        <> command
          "schema"
          ( info
              (Schema <$> schemaParser)
              ( progDesc "Print the cardano-node configuration JSON Schema."
                  <> footerDoc (Just schemaValidationHelp)
              )
          )
        <> command
          "migrate"
          ( info
              ( Migrate
                  <$> strArgument
                    (metavar "CONFIG" <> help "Configuration file to migrate (JSON or YAML), or - for stdin.")
              )
              ( progDesc
                  ( "Reshape a configuration into the recommended "
                      <> "{ $schema, Version, MinNodeVersion, Configuration } envelope and print it as JSON. "
                      <> "Preserves the values as written (no defaults are filled, no sub-files inlined)."
                  )
              )
          )
    )

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

-- | Parser for the @schema@ subcommand options.
schemaParser :: Parser SchemaCmd
schemaParser =
  flag'
    SchemaList
    (long "list" <> help "List the available component names.")
    <|> flag'
      (SchemaWhole LegacyOneFileForm)
      ( long "legacy-one-file"
          <> help
            ( "Dump the legacy single-file schema (every key flat at the top level). "
                <> "Prefer the default split-file schema for new configurations."
            )
      )
    <|> ( maybe (SchemaWhole SplitForm) SchemaComponent
            <$> optional
              ( strArgument
                  ( metavar "COMPONENT"
                      <> help
                        "Dump the schema for a single component (default: the whole configuration, split-file form)."
                  )
              )
        )

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

-- | Execute the selected command.
run :: Command -> IO ()
run (Resolve cli geneses) = runResolve cli geneses
run (Schema cmd) = runSchema cmd
run (Migrate path) = runMigrate path

-- | Read a configuration and print it, reshaped into the Version1 envelope, as
-- JSON. A purely structural migration: it does not resolve, default or validate.
-- A path of @-@ reads the configuration from stdin (so it composes with @curl@).
runMigrate :: FilePath -> IO ()
runMigrate path = handleAny (die . displayException) $ do
  raw <- case path of
    "-" -> BS.getContents >>= decodeThrow
    _ -> decodeValueFile Nothing path
  dump (migrate raw)

-- | Resolve a configuration and print it as YAML.
runResolve :: CliArgs -> GenesisRendering -> IO ()
runResolve cli geneses = handleAny (die . displayException) $ do
  (file, warnings) <- parseConfigurationFiles (configFilePath cli)
  for_ warnings $ hPutStrLn stderr . ("Warning: " <>) . renderConfigWarning
  (nc, resolveWarnings) <- either throwIO pure $ resolveConfiguration cli file
  for_ resolveWarnings $ hPutStrLn stderr . ("Warning: " <>) . renderConfigWarning
  BS.putStr $ encodePretty yamlConfig (nodeConfigurationToJSON geneses nc)
 where
  -- Stable, readable output: keys sorted alphabetically, unset values omitted.
  yamlConfig = setConfDropNull True $ setConfCompare compare Yaml.defConfig

-- | Print a JSON Schema, or list the component names.
runSchema :: SchemaCmd -> IO ()
runSchema SchemaList = mapM_ (putStrLn . T.unpack . fst) configurationSchemas
runSchema (SchemaWhole form) = do
  defs <- componentDefaults
  dump $ case form of
    SplitForm -> splitConfigSchemaWithDefaults defs
    LegacyOneFileForm -> legacyOneFileConfigSchemaWithDefaults defs
runSchema (SchemaComponent name) = do
  defs <- componentDefaults
  case lookup (T.pack name) (configurationSchemasWithDefaults defs) of
    Just s -> dump s
    Nothing ->
      die $
        "Unknown component: "
          <> name
          <> "\nAvailable components: "
          <> intercalate ", " (map (T.unpack . fst) configurationSchemas)

-- | Print a schema with sorted keys for stable output.
dump :: Value -> IO ()
dump = L.putStrLn . encodePretty' defConfig{confCompare = compare}

-- | Print a message to @stderr@ and exit with a failure status.
die :: String -> IO a
die msg = hPutStrLn stderr msg >> exitFailure
