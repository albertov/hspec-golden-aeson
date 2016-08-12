{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

module Test.Aeson.Internal.ADT.GoldenSpecs where

import           Control.Arrow
import           Control.Exception
import           Control.Monad

import           Data.Aeson                (ToJSON, FromJSON)
import qualified Data.Aeson                as A
import           Data.Aeson.Encode.Pretty
import           Data.ByteString.Lazy      (writeFile, readFile)
import           Data.Proxy

import           Prelude            hiding (writeFile,readFile)

import           System.Directory
import           System.FilePath
import           System.Random

import           Test.Aeson.Internal.RandomSamples
import           Test.Hspec
import           Test.QuickCheck
import           Test.QuickCheck.Arbitrary.ADT

-- | for a type a, create a set of golden files if they do not exist, compare
-- with golden file if it exists. Golden file encodes json format of a type
goldenADTSpecs :: forall a. (ToADTArbitrary a, Eq a, Show a, Arbitrary a, ToJSON a, FromJSON a) =>
  Int -> Proxy a -> Spec
goldenADTSpecs sampleSize proxy = goldenADTSpecsWithNote sampleSize proxy Nothing

goldenADTSpecsWithNote :: forall a. (ToADTArbitrary a, Eq a, Show a, Arbitrary a, ToJSON a, FromJSON a) =>
  Int -> Proxy a -> Maybe String -> Spec
goldenADTSpecsWithNote sampleSize Proxy mNote = do
  (typeName,constructors) <- runIO $ fmap (_adtTypeName &&& _adtCAPs) <$> generate $ toADTArbitrary (Proxy :: Proxy a)
  describe ("JSON encoding of " ++ typeName ++ note) $
    mapM_ (testConstructor sampleSize typeName) constructors
  where
    note = maybe "" (" " ++) mNote

testConstructor :: forall a. (Eq a, Show a, FromJSON a, ToJSON a, ToADTArbitrary a) =>
  Int -> String -> ConstructorArbitraryPair a -> SpecWith ( Arg (IO ()))
testConstructor sampleSize typeName cap =
  it ("produces the same JSON as is found in " ++ goldenFile) $ do
    exists <- doesFileExist goldenFile
    if exists
      then compareWithGolden typeName cap goldenFile
      else createGoldenFile sampleSize cap goldenFile
  where
    goldenFile = mkGoldenFilePath typeName cap

compareWithGolden :: forall a. (Show a, Eq a, FromJSON a, ToJSON a, ToADTArbitrary a) =>
  String -> ConstructorArbitraryPair a -> FilePath -> IO ()
compareWithGolden typeName cap goldenFile = do
  goldenSeed <- readSeed =<< readFile goldenFile
  sampleSize <- readSampleSize =<< readFile goldenFile
  newSamples <- mkRandomADTSamplesForConstructor sampleSize (Proxy :: Proxy a) (_capConstructor cap) goldenSeed
  whenFails (writeComparisonFile newSamples) $ do
    goldenSamples :: RandomSamples a <-
      either (throwIO . ErrorCall) return =<<
      A.eitherDecode' <$>
      readFile goldenFile
    newSamples `shouldBe` goldenSamples
  where
    whenFails :: forall b c. IO c -> IO b -> IO b
    whenFails = flip onException
    faultyFile = mkFaultyFilePath typeName cap
    writeComparisonFile newSamples = do
      writeFile faultyFile (encodePretty newSamples)
      putStrLn $
        "\n" ++
        "INFO: Written the current encodings into " ++ faultyFile ++ "."

createGoldenFile :: forall a. (ToJSON a, ToADTArbitrary a) =>
  Int -> ConstructorArbitraryPair a -> FilePath -> IO ()
createGoldenFile sampleSize cap goldenFile = do
  createDirectoryIfMissing True (takeDirectory goldenFile)
  rSeed <- randomIO :: IO Int
  rSamples <- mkRandomADTSamplesForConstructor sampleSize (Proxy :: Proxy a) (_capConstructor cap) rSeed
  writeFile goldenFile $ encodePretty rSamples

  putStrLn $
    "\n" ++
    "WARNING: Running for the first time, not testing anything.\n" ++
    "  Created " ++ goldenFile ++ " containing random samples,\n" ++
    "  will compare JSON encodings with this from now on.\n" ++
    "  Please, consider putting " ++ goldenFile ++ " under version control."

mkGoldenFilePath :: forall a. String -> ConstructorArbitraryPair a -> FilePath
mkGoldenFilePath typeName cap = "golden" </> typeName </> _capConstructor cap <.> "json"

mkFaultyFilePath :: forall a. String -> ConstructorArbitraryPair a -> FilePath
mkFaultyFilePath typeName cap = "golden" </> typeName </> _capConstructor cap <.> "faulty" <.> "json"

mkRandomADTSamplesForConstructor :: forall a. (ToADTArbitrary a) =>
  Int -> Proxy a -> String -> Int -> IO (RandomSamples a)
mkRandomADTSamplesForConstructor sampleSize Proxy conName rSeed = do
  generatedADTs <- generate gen
  let caps         = concat $ _adtCAPs <$> generatedADTs
      filteredCAPs = filter (\x -> _capConstructor x == conName) caps
      arbs         = _capArbitrary <$> filteredCAPs
  return $ RandomSamples rSeed arbs
  where
    correctedSampleSize = if sampleSize <= 0 then 1 else sampleSize
    gen = setSeed rSeed $ replicateM sampleSize (toADTArbitrary (Proxy :: Proxy a))
