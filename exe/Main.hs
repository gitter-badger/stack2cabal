{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import StackageToHackage.Hackage (printFreeze, printProject, stackToCabal)
import StackageToHackage.Stackage (localDirs, readStack)

import Control.Monad (filterM, when)
import Data.Foldable (traverse_)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Hpack (Force(..), Options(..), defaultOptions, hpackResult, setTarget)
import Options.Applicative
import Prelude hiding (lines)
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath (takeDirectory, (</>))

import qualified Data.ByteString as BS
import qualified Data.List.NonEmpty as NEL
import qualified Data.Text as T


version :: String
#ifdef CURRENT_PACKAGE_VERSION
version = CURRENT_PACKAGE_VERSION
#else
version = "unknown"
#endif


data Opts = Opts
  { input :: FilePath
  , output :: Maybe FilePath
  , inspectRemotes :: Bool
  , pinGHC :: Bool
  , runHpack :: Bool
  }


optsP :: Parser Opts
optsP =
    Opts
        <$> strOption
                (short 'f'
                <> long "file"
                <> metavar "STACK_YAML"
                <> help "Path to stack.yaml file"
                <> value "stack.yaml"
                <> showDefaultWith show
                )
        <*> optional
                (strOption
                    (short 'o'
                    <> long "output-file"
                    <> metavar "CABAL_PROJECT"
                    <> help
                           "Path to output file (default depends on input file)"
                    <> showDefaultWith show
                    )
                )
        <*> (not <$> switch
                (long "no-inspect-remotes"
                <> help
                       "Don't check package names from remote git sources (this is faster, but may leave incorrect versions in cabal.project.freeze if remote packages overwrite stack resolver versions)"
                )
            )
        <*> (not <$> switch
                (long "no-pin-ghc" <> help "Don't pin the GHC version")
            )
        <*> (not <$> switch (long "no-run-hpack" <> help "Don't run hpack"))



main :: IO ()
main = do
    let versionHelp = infoOption version (long "version" <> help "Show version" <> hidden)

    customExecParser (prefs showHelpOnError) (info (optsP <**> helper <**> versionHelp) idm) >>= \Opts {..} -> do
        -- read stack file
        inDir <- makeAbsolute (takeDirectory input)
        stack <- readStack =<< BS.readFile input

        let subs = NEL.toList $ (inDir </>) <$> localDirs stack
        when runHpack $ do
            hpacks <-
                filterM (doesFileExist . hpackInput) subs
            traverse_ execHpack hpacks

        -- run conversion
        (project, freeze) <- stackToCabal inspectRemotes inDir stack
        hack <- extractHack . decodeUtf8 <$> BS.readFile
            (inDir </> "stack.yaml")
        printText <- printProject pinGHC project hack

        -- write files
        outFile <- case output of
            Just output' -> (</> "cabal.project")
                <$> makeAbsolute (takeDirectory output')
            Nothing -> pure (inDir </> "cabal.project")
        BS.writeFile outFile (encodeUtf8 printText)
        BS.writeFile
            (outFile <> ".freeze")
            (encodeUtf8 $ printFreeze freeze)
  where
    hpackInput sub = sub </> "package.yaml"
    opts = defaultOptions { optionsForce = Force }
    execHpack sub = hpackResult $ setTarget (hpackInput sub) opts


-- Backdoor allowing the stack.yaml to contain arbitrary text that will be
-- included in the cabal.project
extractHack :: Text -> Maybe Text
extractHack (T.split ('\n' ==) -> lines) =
    let (_, region) = break (T.isPrefixOf "#+BEGIN_STACK2CABAL") lines
        (hack, _) = break (T.isPrefixOf "#+END_STACK2CABAL") region
        verbatim = mapMaybe (T.stripPrefix "# ") hack
    in if null verbatim then Nothing else Just $ T.intercalate "\n" verbatim
