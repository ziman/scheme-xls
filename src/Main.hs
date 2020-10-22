module Main where

import Control.Monad
import Data.Foldable
import Data.SCargot
import Data.List (intercalate)
import qualified Data.Text.IO as Text

import Parser
import AST
import Compile
import Bytecode
import Interpret
import Xls

main :: IO ()
main = do
  input <- Text.getContents
  let parser = asRich $ mkParser $ parseAtom
      pipeline =
        decode parser
        >=> traverse astDef
        >=> compile
        >=> resolve
  case pipeline input of
    Left err -> error err
    Right code -> do
      for_ (zip [0..] code) $ \(pc, instr) -> do
        putStrLn $ show (pc :: Int) ++ ": " ++ show instr

      run code >>= \case
        Left err -> error err
        Right stats -> do
          print stats

          let icode = toICode code
          writeFile "output.tsv" $ unlines
            [ intercalate "\t"
              [ toExcel row $ xeCell icode (Addr addr)
              | addr <- [0..stSpace stats-1]
              ]
            | row <- [0..stTime stats]
            ]
