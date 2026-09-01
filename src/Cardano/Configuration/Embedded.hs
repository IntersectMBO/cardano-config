{-# LANGUAGE TemplateHaskell #-}

-- | The base defaults under @defaults\/@, embedded into the compiled artefact.
--
-- These are the only JSON files the library reads at run time (see
-- 'Cardano.Configuration.File.Merge.loadBaseDefault'). Embedding them means a
-- distributed executable does not have to locate a Cabal data directory, and
-- the defaults are compiled in, so they cannot go missing or drift out of step
-- with the binary.
--
-- The other JSON the repository ships is not needed here: @schemas\/@ holds
-- committed /outputs/, regenerated from the codecs by
-- "Cardano.Configuration.Schema" and only compared against by the test suite,
-- and @variants\/@ holds overlays a configuration references by a path relative
-- to its own directory, so they are read as ordinary files from wherever the
-- user put them.
--
-- The files stay committed to the repository (and listed in
-- @extra-source-files@, so they reach a source distribution): they are the
-- source of truth, read by Template Haskell at build time. Editing one triggers
-- a rebuild of this module.
module Cardano.Configuration.Embedded
  ( embeddedDefaults
  ) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir, makeRelativeToProject)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

-- | The contents of @defaults\/@, keyed by path relative to that directory:
-- @\"ConsensusConfig.json\"@, @\"NetworkConfig\/relay.json\"@, and so on. The
-- keys are spelled with @\/@ separators on every platform, so they do not
-- depend on the machine the package was built on.
embeddedDefaults :: Map FilePath ByteString
embeddedDefaults =
  Map.fromList
    [ (map forwardSlash path, contents)
    | (path, contents) <- $(makeRelativeToProject "defaults" >>= embedDir)
    ]
 where
  forwardSlash '\\' = '/'
  forwardSlash c = c
