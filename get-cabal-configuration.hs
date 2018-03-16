-- Copyright (C) 2016-2018 Sergey Vinokurov <serg.foo@gmail.com>
-- Copyright (C) 2014-2016 Sebastian Wiesner <swiesner@lunaryorn.com>
-- Copyright (C) 2016 Danny Navarro
-- Copyright (C) 2015 Mark Karpov <markkarpov@opmbx.org>
-- Copyright (C) 2015 Michael Alan Dorman <mdorman@ironicdesign.com>
-- Copyright (C) 2014 Gracjan Polak <gracjanpolak@gmail.com>

-- This file is not part of GNU Emacs.

-- This program is free software; you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version.

-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
-- details.

-- You should have received a copy of the GNU General Public License along with
-- this program.  If not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE CPP                  #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Main (main) where

#if __GLASGOW_HASKELL__ >= 800
# if MIN_VERSION_Cabal(2,2,0)
#  define Cabal22 1
# elif MIN_VERSION_Cabal(2,0,0)
#  define Cabal20 1
# endif
#else
-- Hack - we may actually be using Cabal 2.0 with e.g. 7.8 GHC. But
-- that's not likely to occur for average user who's relying on
-- packages bundled with GHC. The 2.0 Cabal is bundled starting with 8.2.1.
#undef Cabal22
#undef Cabal20
#endif

import qualified Control.Applicative as A
import Control.Exception (SomeException, try)
import Control.Monad (when)
#if defined(Cabal22)
import qualified Data.ByteString as BS
#endif
import Data.Char (isSpace)
import Data.Functor.Identity
import Data.List (isPrefixOf, nub, foldl')
import Data.Set (Set)
import qualified Data.Set as S
#ifdef USE_COMPILER_ID
import Distribution.Compiler
       (CompilerFlavor(GHC), CompilerId(CompilerId), buildCompilerFlavor)
#else
import Distribution.Compiler
       (AbiTag(NoAbiTag), CompilerFlavor(GHC), CompilerId(CompilerId),
        CompilerInfo, buildCompilerFlavor, unknownCompilerInfo)
#endif
import Distribution.Package
       (pkgName, Dependency(..))
import Distribution.PackageDescription
       (GenericPackageDescription,
        PackageDescription(..), allBuildInfo, BuildInfo(..),
        usedExtensions, allLanguages, hcOptions, exeName,
        Executable)
import Distribution.Simple.BuildPaths (defaultDistPref)
import Distribution.Simple.Utils (cabalVersion)
import Distribution.System (buildPlatform)
import Distribution.Text (display)
import Distribution.Verbosity (silent)
import Language.Haskell.Extension (Extension(..),Language(..))
import System.Console.GetOpt
import System.Environment (getArgs)
import System.Exit (ExitCode(..), exitFailure, exitSuccess)
import System.FilePath ((</>),dropFileName,normalise)
import System.Info (compilerVersion)
import System.IO (Handle, hGetContents, hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import qualified System.Process as Process

#if __GLASGOW_HASKELL__ >= 710 && !defined(Cabal20) && !defined(Cabal22)
import Data.Version (Version)
#endif

#if defined(Cabal20) || defined(Cabal22)
import Control.Monad (filterM)
import Distribution.Package (unPackageName, depPkgName, PackageName)
import Distribution.PackageDescription.Configuration (finalizePD)
import Distribution.Types.ComponentRequestedSpec (ComponentRequestedSpec(..))
import Distribution.Types.UnqualComponentName (unUnqualComponentName)
import qualified Distribution.Version as CabalVersion
import Distribution.Types.Benchmark (Benchmark(benchmarkName))
import Distribution.Types.TestSuite (TestSuite(testName))
import System.Directory (doesDirectoryExist)
#else
import Control.Arrow (second)
import Data.Version (showVersion)
import Distribution.Package (PackageName(..))
import Distribution.PackageDescription
       (TestSuite(..), Benchmark(..), condTestSuites, condBenchmarks,
        benchmarkEnabled, testEnabled)
import Distribution.PackageDescription.Configuration
       (finalizePackageDescription, mapTreeData)
#endif

#if defined(Cabal22)
import Distribution.Pretty (prettyShow)
import Distribution.Types.GenericPackageDescription (mkFlagAssignment)
#endif

#if defined(Cabal22)
import Distribution.PackageDescription.Parsec
       (runParseResult, readGenericPackageDescription, parseGenericPackageDescription)
import Distribution.Parsec.Common (showPError)
#elif defined(Cabal20)
import Distribution.PackageDescription.Parse
       (ParseResult(..), readGenericPackageDescription, parseGenericPackageDescription)
import Distribution.ParseUtils (locatedErrorMsg)
#else
import Distribution.PackageDescription.Parse
       (ParseResult(..), parsePackageDescription, readPackageDescription)
import Distribution.ParseUtils (locatedErrorMsg)
#endif

data Sexp
    = SList [Sexp]
    | SString String
    | SSymbol String

data TargetTool = Cabal | Stack

sym :: String -> Sexp
sym = SSymbol

instance Show Sexp where
    show (SSymbol s) = s
    show (SString s) = show s     -- Poor man's escaping
    show (SList s) = "(" ++ unwords (map show s) ++ ")"

class ToSexp a  where
    toSexp :: a -> Sexp

instance ToSexp String where
    toSexp = SString

instance ToSexp Extension where
    toSexp (EnableExtension ext) = toSexp (show ext)
    toSexp (DisableExtension ext) = toSexp ("No" ++ show ext)
    toSexp (UnknownExtension ext) = toSexp ext

instance ToSexp Language where
    toSexp (UnknownLanguage lang) = toSexp lang
    toSexp lang = toSexp (show lang)

instance ToSexp Dependency where
#if defined(Cabal20) || defined(Cabal22)
    toSexp = toSexp . unPackageName . depPkgName
#else
    toSexp (Dependency (PackageName dependency) _) = toSexp dependency
#endif

instance ToSexp Sexp where
    toSexp = id

cons :: (ToSexp a, ToSexp b) => a -> [b] -> Sexp
cons h t = SList (toSexp h : map toSexp t)

-- | Get possible dist directory
distDir :: TargetTool -> IO FilePath
distDir Cabal = return defaultDistPref
distDir Stack = do
    res <- try $ readProcessWithExitCode "stack" ["path", "--dist-dir"] []
    return $ case res of
        Left (_ :: SomeException)      -> defaultDistDir
        Right (ExitSuccess, stdOut, _) -> stripWhitespace stdOut
        Right (ExitFailure _, _, _)    -> defaultDistDir
  where
    defaultDistDir :: FilePath
    defaultDistDir =
        ".stack-work" </> defaultDistPref
                      </> display buildPlatform
                      </> "Cabal-" ++ cabalVersion'

getBuildDirectories
    :: TargetTool
    -> PackageDescription
    -> FilePath
    -> IO ([FilePath], [FilePath])
getBuildDirectories tool pkgDesc cabalDir = do
    distDir' <- distDir tool
    let buildDir   :: FilePath
        buildDir   = cabalDir </> distDir' </> "build"

        componentNames :: [String]
        componentNames =
            map getExeName   (executables pkgDesc) ++
            map getTestName  (testSuites pkgDesc) ++
            map getBenchName (benchmarks pkgDesc)

    autogenDirs <- getAutogenDirs buildDir componentNames

    let componentBuildDir :: String -> FilePath
        componentBuildDir componentName =
            buildDir </> componentName </> (componentName ++ "-tmp")

        buildDirs :: [FilePath]
        buildDirs =
            autogenDirs ++
            map componentBuildDir componentNames

        buildDirs' = case library pkgDesc of
            Just _  -> buildDir : buildDirs
            Nothing -> buildDirs
    return (buildDirs', autogenDirs)

getAutogenDirs :: FilePath -> [String] -> IO [FilePath]
getAutogenDirs buildDir componentNames =
    fmap (autogenDir :) $ componentsAutogenDirs buildDir componentNames
  where
    -- 'dist/bulid/autogen' OR '.stack-work/dist/x86_64-linux/Cabal-1.24.2.0/build/autogen'
    autogenDir :: FilePath
    autogenDir = buildDir </> "autogen"

getSourceDirectories :: [BuildInfo] -> FilePath -> [String]
getSourceDirectories buildInfo cabalDir =
    map (cabalDir </>) (concatMap hsSourceDirs buildInfo)

allowedOptions :: Set String
allowedOptions = S.fromList
    [ "-W"
    , "-w"
    , "-Wall"
    , "-fglasgow-exts"
    , "-fpackage-trust"
    , "-fhelpful-errors"
    , "-F"
    , "-cpp"
    ]

allowedOptionPrefixes :: [String]
allowedOptionPrefixes =
    [ "-fwarn-"
    , "-fno-warn-"
    , "-fcontext-stack="
    , "-firrefutable-tuples"
    , "-D"
    , "-U"
    , "-I"
    , "-fplugin="
    , "-fplugin-opt="
    , "-pgm"
    , "-opt"
    ]

isAllowedOption :: String -> Bool
isAllowedOption opt =
    S.member opt allowedOptions || any (`isPrefixOf` opt) allowedOptionPrefixes

dumpPackageDescription :: PackageDescription -> FilePath -> IO Sexp
dumpPackageDescription pkgDesc projectDir = do
    (cabalDirs, cabalAutogen) <- getBuildDirectories Cabal pkgDesc projectDir
    (stackDirs, stackAutogen) <- getBuildDirectories Stack pkgDesc projectDir
    let buildDirs   = cabalDirs ++ stackDirs
        autogenDirs = cabalAutogen ++ stackAutogen
    return $
        SList
            [ cons (sym "build-directories") (ordNub (map normalise buildDirs))
            , cons (sym "source-directories") sourceDirs
            , cons (sym "extensions") exts
            , cons (sym "languages") langs
            , cons (sym "dependencies") deps
            , cons (sym "other-options") (cppOpts ++ ghcOpts)
            , cons (sym "autogen-directories") (map normalise autogenDirs)
            ]
  where
    buildInfo :: [BuildInfo]
    buildInfo = allBuildInfo pkgDesc
    sourceDirs :: [FilePath]
    sourceDirs = ordNub (map normalise (getSourceDirectories buildInfo projectDir))
    exts :: [Extension]
    exts = nub (concatMap usedExtensions buildInfo)
    langs :: [Language]
    langs = nub (concatMap allLanguages buildInfo)
    thisPackage :: PackageName
    thisPackage = pkgName (package pkgDesc)
    deps :: [Dependency]
    deps =
        nub (filter (\(Dependency name _) -> name /= thisPackage) (buildDepends pkgDesc))
    -- The "cpp-options" configuration field.
    cppOpts :: [String]
    cppOpts =
        ordNub (filter isAllowedOption (concatMap cppOptions buildInfo))
    -- The "ghc-options" configuration field.
    ghcOpts :: [String]
    ghcOpts =
        ordNub (filter isAllowedOption (concatMap (hcOptions GHC) buildInfo))

getCabalConfiguration :: HPackExe -> ConfigurationFile -> IO Sexp
getCabalConfiguration hpackExe configFile = do
    genericDesc <-
        case configFile of
            HPackFile path -> readHPackPkgDescr hpackExe path projectDir
            CabalFile path -> readGenericPkgDescr path
    case getConcretePackageDescription genericDesc of
        Left e        -> die' $ "Issue with package configuration\n" ++ show e
        Right pkgDesc -> dumpPackageDescription pkgDesc projectDir
  where
    projectDir :: FilePath
    projectDir = dropFileName $ configFilePath configFile

readHPackPkgDescr :: HPackExe -> FilePath -> FilePath -> IO GenericPackageDescription
readHPackPkgDescr exe configFile projectDir = do
    (Nothing, Just out, Just err, procHandle) <- Process.createProcess p
    cabalFileContents <- readCabalFileContentsFromHandle out
    exitCode <- Process.waitForProcess procHandle
    case exitCode of
        ExitFailure{} -> do
            err' <- hGetContents err
            die' $ "Failed to obtain cabal configuration by running hpack on '" ++ configFile ++ "':\n" ++ err'
        ExitSuccess ->
            case parsePkgDescr "<generated by hpack>" cabalFileContents of
                Left msgs ->
                    die' $ "Failed to parse cabal file produced by hpack from '" ++ configFile ++ "':\n" ++
                        unlines msgs
                Right x   -> return x
  where
    p = (Process.proc (unHPackExe exe) [configFile, "-"])
        { Process.std_in  = Process.Inherit
        , Process.std_out = Process.CreatePipe
        , Process.std_err = Process.CreatePipe
        , Process.cwd     = Just projectDir
        }

readGenericPkgDescr :: FilePath -> IO GenericPackageDescription
readGenericPkgDescr configFile =
#if defined(Cabal20) || defined(Cabal22)
    readGenericPackageDescription silent configFile
#else
    readPackageDescription silent configFile
#endif

newtype CabalFileContents = CabalFileContents
    { unCabalFileContents ::
#if defined(Cabal22)
        BS.ByteString
#else
        String
#endif
    }

readCabalFileContentsFromHandle :: Handle -> IO CabalFileContents
readCabalFileContentsFromHandle =
    fmap CabalFileContents .
#if defined(Cabal22)
        BS.hGetContents
#else
        hGetContents
#endif

parsePkgDescr :: FilePath -> CabalFileContents -> Either [String] GenericPackageDescription
parsePkgDescr _fileName cabalFileContents =
#if defined(Cabal22)
    case runParseResult $ parseGenericPackageDescription $ unCabalFileContents cabalFileContents of
        (_warnings, res) ->
            case res of
                Left (_version, errs) -> Left $ map (showPError _fileName) errs
                Right x -> return x
#elif defined(Cabal20)
    case parseGenericPackageDescription $ unCabalFileContents cabalFileContents of
        ParseFailed failure ->
            let (_line, msg) = locatedErrorMsg failure
            in Left [msg]
        ParseOk _warnings x  -> Right x
#else
    case parsePackageDescription $ unCabalFileContents cabalFileContents of
        ParseFailed failure ->
            let (_line, msg) = locatedErrorMsg failure
            in Left [msg]
        ParseOk _warnings x  -> Right x
#endif

getConcretePackageDescription
    :: GenericPackageDescription
    -> Either [Dependency] PackageDescription
getConcretePackageDescription genericDesc = do
#if defined(Cabal22)
    let enabled :: ComponentRequestedSpec
        enabled = ComponentRequestedSpec
            { testsRequested      = True
            , benchmarksRequested = True
            }
    fst A.<$> finalizePD
        (mkFlagAssignment []) -- Flag assignment
        enabled               -- Enable all components
        (const True)          -- Whether given dependency is available
        buildPlatform
        buildCompilerId
        []                    -- Additional constraints
        genericDesc
#elif defined(Cabal20)
    let enabled :: ComponentRequestedSpec
        enabled = ComponentRequestedSpec
            { testsRequested      = True
            , benchmarksRequested = True
            }
    fst A.<$> finalizePD
        []           -- Flag assignment
        enabled      -- Enable all components
        (const True) -- Whether given dependency is available
        buildPlatform
        buildCompilerId
        []           -- Additional constraints
        genericDesc
#else
    -- This let block is eerily like one in Cabal.Distribution.Simple.Configure
    let enableTest :: TestSuite -> TestSuite
        enableTest t = t { testEnabled = True }
        enableBenchmark :: Benchmark -> Benchmark
        enableBenchmark bm = bm { benchmarkEnabled = True }
        flaggedTests =
            map (second (mapTreeData enableTest)) (condTestSuites genericDesc)
        flaggedBenchmarks =
            map
                (second (mapTreeData enableBenchmark))
                (condBenchmarks genericDesc)
        genericDesc' =
            genericDesc
            { condTestSuites = flaggedTests
            , condBenchmarks = flaggedBenchmarks
            }
    fst A.<$> finalizePackageDescription
        []
        (const True)
        buildPlatform
        buildCompilerId
        []
        genericDesc'
#endif

componentsAutogenDirs :: FilePath -> [String] -> IO [FilePath]
#if defined(Cabal20) || defined(Cabal22)
componentsAutogenDirs buildDir componentNames =
        filterM doesDirectoryExist $
            map (\path -> buildDir </> path </> "autogen") componentNames
#else
componentsAutogenDirs _ _ = return []
#endif

#if defined(USE_COMPILER_ID)
buildCompilerId :: CompilerId
buildCompilerId = CompilerId buildCompilerFlavor compilerVersion
#else
buildCompilerId :: CompilerInfo
buildCompilerId = unknownCompilerInfo compId NoAbiTag
  where
    compId :: CompilerId
    compId = CompilerId buildCompilerFlavor compVersion
# if defined(Cabal20) || defined(Cabal22)
    compVersion :: CabalVersion.Version
    compVersion = CabalVersion.mkVersion' compilerVersion
# else
    compVersion :: Version
    compVersion = compilerVersion
# endif
#endif

getExeName :: Executable -> FilePath
getExeName =
#if defined(Cabal20) || defined(Cabal22)
    unUnqualComponentName . exeName
#else
    exeName
#endif

getTestName :: TestSuite -> FilePath
getTestName =
#if defined(Cabal20) || defined(Cabal22)
    unUnqualComponentName . testName
#else
    testName
#endif

getBenchName :: Benchmark -> FilePath
getBenchName =
#if defined(Cabal20) || defined(Cabal22)
    unUnqualComponentName . benchmarkName
#else
    benchmarkName
#endif

-- Textual representation of cabal version
cabalVersion' :: String
cabalVersion' =
#if defined(Cabal22)
    prettyShow cabalVersion
#elif defined(Cabal20)
    CabalVersion.showVersion cabalVersion
#else
    showVersion cabalVersion
#endif

ordNub :: forall a. Ord a => [a] -> [a]
ordNub = go S.empty
  where
    go :: Set a -> [a] -> [a]
    go _   []     = []
    go acc (x:xs)
        | S.member x acc = go acc xs
        | otherwise      = x : go (S.insert x acc) xs

stripWhitespace :: String -> String
stripWhitespace = reverse . dropWhile isSpace . reverse . dropWhile isSpace

die' :: String -> IO a
die' msg = do
    hPutStrLn stderr msg
    exitFailure

data ConfigurationFile =
      CabalFile FilePath
    | HPackFile FilePath

configFilePath :: ConfigurationFile -> FilePath
configFilePath (CabalFile path) = path
configFilePath (HPackFile path) = path

newtype HPackExe = HPackExe { unHPackExe :: FilePath }

data Config f = Config
    { cfgInputFile :: f ConfigurationFile
    , cfgHPackExe  :: HPackExe
    }

reifyConfig :: Config Maybe -> IO (Config Identity)
reifyConfig Config{cfgInputFile, cfgHPackExe} = do
    cfgInputFile' <- case cfgInputFile of
        Nothing   -> die' $ "Input file not specified. Use --cabal-file or --hpack-file to specify one."
        Just path -> return path
    return Config
        { cfgInputFile = Identity cfgInputFile'
        , cfgHPackExe
        }

optionDescr :: [OptDescr (Config Maybe -> Config Maybe)]
optionDescr =
    [ Option
          []
          ["cabal-file"]
          (ReqArg (\path cfg -> cfg { cfgInputFile = Just (CabalFile path) }) "FILE")
          "Cabal file to process"
    , Option
          []
          ["hpack-file"]
          (ReqArg (\path cfg -> cfg { cfgInputFile = Just (HPackFile path) }) "FILE")
          "HPack package.yaml file to process"
    , Option
          []
          ["hpack-exe"]
          (ReqArg (\path cfg -> cfg { cfgHPackExe = HPackExe path }) "FILE")
          "Path to 'hpack' executable"
    ]

defaultConfig :: Config Maybe
defaultConfig = Config
    { cfgInputFile = Nothing
    , cfgHPackExe  = HPackExe "hpack"
    }

main' :: Config Identity -> IO ()
main' Config{cfgInputFile, cfgHPackExe} =
    print =<< getCabalConfiguration cfgHPackExe (runIdentity cfgInputFile)

main :: IO ()
main = do
    args <- getArgs
    when (any (`elem` ["-h", "--help"]) args) $ do
        putStrLn usage
        exitSuccess
    case getOpt' RequireOrder optionDescr args of
        (fs, [],  [],  []) -> do
            let cfg = foldl' (flip ($)) defaultConfig fs
            main' =<< reifyConfig cfg
        (_,  x:_, [],  []) ->
            die' $ "Unrecognised argument: " ++ x
        (_,  [],  y:_, []) ->
            die' $ "Unrecognised command-line option: " ++ y
        (_,  _,   _,   es) ->
            die' $ "Failed to parse command-line options:\n" ++ unlines es
  where
    header = "Usage: get-cabal-configuration [OPTION...]"
    usage = usageInfo header optionDescr
