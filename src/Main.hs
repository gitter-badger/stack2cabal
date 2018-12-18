{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ViewPatterns          #-}

import           Control.Monad.Extra            (ifM)
import qualified Data.ByteString                as BS
import           Data.List                      (sort)
import           Data.List.Extra                (nubOn)
import           Data.List.NonEmpty             (NonEmpty, nonEmpty)
import qualified Data.List.NonEmpty             as NEL
import qualified Data.Map.Strict                as M
import           Data.Maybe                     (fromMaybe, mapMaybe)
import           Data.Semigroup                 (sconcat)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Data.Text.Encoding             (encodeUtf8)
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.PackageId   (PackageIdentifier (..))
import           Distribution.Types.PackageName (PackageName, mkPackageName,
                                                 unPackageName)
import qualified Options.Applicative            as Opts
import           Stackage
import           System.Directory               (doesDirectoryExist,
                                                 listDirectory)
import           System.FilePath                (addTrailingPathSeparator,
                                                 takeBaseName, takeDirectory,
                                                 takeExtension, (</>))

main :: IO ()
main = do
  Options{input} <- Opts.execParser $
                   Opts.info (Opts.helper <*> optionsParser) Opts.fullDesc
  text <- BS.readFile input
  stack <- readStack text
  let
    dir = (takeDirectory input)
  resolvers <- unroll dir stack
  let
    resolver = sconcat resolvers
    project = genProject stack resolver
    dirs = NEL.toList $ (dir </>) <$> localDirs project
  cabals <- concat <$> traverse (globExt ".cabal") dirs
  let
    -- assumes that .cabal files are named correctly, otherwise we need
    -- PackageDescription-Parsec.html#v:readGenericPackageDescription
    ignore = (mkPackageName . takeBaseName) <$> cabals
    freeze = genFreeze resolver ignore
  BS.writeFile (dir </> "cabal.project") (encodeUtf8 $ printProject project)
  BS.writeFile (dir </> "cabal.project.freeze") (encodeUtf8 $ printFreeze freeze)

globExt :: String -> FilePath -> IO [FilePath]
globExt ext path = do
  files <- ifM (doesDirectoryExist path) (listDirectory path) (pure [])
  pure $ filter ((ext ==) . takeExtension) files

printProject :: Project -> Text
printProject (Project (Ghc ghc) pkgs srcs) =
  T.concat [ "-- Generated by stackage-to-hackage from stack.yaml\n\n"
         , "with-compiler: ", ghc, "\n\n"
         , "packages:\n    ", packages, "\n\n"
         , sources, "\n"
         , "allow-older: *\n"
         , "allow-newer: *\n"
         ]
  where
    packages = T.intercalate "\n  , " (T.pack . addTrailingPathSeparator <$>
                                     NEL.toList pkgs)
    sources = T.intercalate "\n" (source =<< srcs)
    source Git{repo, commit, subdirs} =
      let base = T.concat [ "source-repository-package\n    "
                        , "type: git\n    "
                        , "location: ", repo, "\n    "
                        , "tag: ", commit, "\n"]
      in if null subdirs
         then [base]
         else (\d -> T.concat [base, "    subdir: ", d, "\n"]) <$> subdirs

data Project = Project Ghc (NonEmpty FilePath) [Git] deriving (Show)

localDirs :: Project -> NonEmpty FilePath
localDirs (Project _ nefp _ ) = nefp

genProject :: Stack -> Resolver -> Project
genProject Stack{packages} Resolver{compiler, deps} = Project
  (fromMaybe (Ghc "ghc") compiler)
  (fromMaybe (pure ".") (nonEmpty $ mapMaybe pickLocal packages))
  (nubOn repo $ mapMaybe pickGit deps)
  where
    pickLocal (Local p)    = Just p
    pickLocal (Location _) = Nothing
    pickGit (Hackage _ )  = Nothing
    pickGit (SourceDep g) = Just g

printFreeze :: Freeze -> Text
printFreeze (Freeze deps (Flags flags)) =
  T.concat [ "constraints:\n    ", constraints, "\n"]
  where
    constraints = T.intercalate "\n  , " (constrait <$> sort deps)
    constrait pkg =
      let name = (T.pack . unPackageName . pkgName $ pkg)
          ver  = (T.pack . prettyShow . pkgVersion $ pkg)
          base = T.concat [name, " ==", ver]
      in case M.lookup name flags of
        Nothing      -> base
        Just entries -> T.concat [ name, " ", (custom entries)
                                 , "\n  , ", base]
    custom (M.toList -> lst) = T.intercalate " " $ (renderFlag <$> lst)
    renderFlag (name, True)  = "+" <> name
    renderFlag (name, False) = "-" <> name

data Freeze = Freeze [PackageIdentifier] Flags deriving (Show)

genFreeze :: Resolver -> [PackageName] -> Freeze
genFreeze Resolver{deps, flags} ignore =
  let pkgs = filter noSelfs $ unPkgId <$> mapMaybe pick deps
      uniqpkgs = nubOn pkgName pkgs
   in Freeze uniqpkgs flags
  where pick (Hackage p)   = Just p
        pick (SourceDep _) = Nothing
        noSelfs (pkgName -> n) = notElem n ignore

data Options = Options
  { input      :: FilePath
  }
optionsParser :: Opts.Parser Options
optionsParser = Options
  <$> file
  where
    file = Opts.strArgument
             (  Opts.metavar "FILENAME"
             <> Opts.help "Input stack.yaml")
