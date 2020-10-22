module Compile (compile, resolve) where

import Prelude
import Data.Functor
import Data.Foldable
import Data.Map (Map)
import qualified Data.Map as Map

import Control.Monad (when)
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Control.Monad.Trans.RWS.CPS

import AST
import Bytecode

data State = State
  { stFreshLabels :: Int
  }

data Env = Env
  { envScope :: [Def]
  , envArity :: Map String Int
  }

type CG = RWST Env (Code String) State (Except String)

throw :: String -> CG a
throw = lift . throwE

emit :: Instr String -> CG ()
emit instr = tell [instr]

freshLabel :: CG String
freshLabel = do
  st <- get
  put st{ stFreshLabels = stFreshLabels st + 1 }
  return $ "_" ++ show (stFreshLabels st)

unsnoc :: [a] -> Maybe ([a], a)
unsnoc [] = Nothing
unsnoc (x:xs) = case unsnoc xs of
  Nothing      -> Just (  [], x)
  Just (ys, z) -> Just (x:ys, z)

type Arity = Int
data Position = Tail Arity | NonTail

compileExpr :: Position -> Expr -> CG ()

compileExpr _pos (Int i) = do
  emit $ OP 0 (XInt i)

compileExpr _pos (Str s) = do
  emit $ OP 0 (XStr s)

compileExpr _pos (Var s) =
  ask <&> envScope >>= \case
    [] -> throw "no variables in global scope"
    scope : _parentScopes ->
      case lookup s (zip (reverse $ defArgs scope) [0..]) of
        Nothing -> throw $ "unknown variable: " ++ show s
        Just i  -> emit $ LLOAD (2 + i)

compileExpr pos (Form "begin" es) =
  case unsnoc es of
    Nothing -> throw $ "begin requires arguments"
    Just (sideEffects, retVal) -> do
      for_ sideEffects $ \se -> do
        compileExpr NonTail se
        emit $ POP 1

      compileExpr pos retVal

compileExpr _pos (Form "display" [xe]) = do
  compileExpr NonTail xe
  emit $ PRINT
  -- returns the printed value

compileExpr _pos (Form op [xe, ye]) | op `elem` ["*","-","/","+"] = do
  compileExpr NonTail xe
  compileExpr NonTail ye
  emit $ OP 2 $ XOp op (XTop 1) (XTop 0)

compileExpr pos (Form "if-zero" [c, t, e]) = do
  lblThen <- freshLabel
  lblEnd <- freshLabel

  compileExpr NonTail c
  emit $ JZ lblThen
  compileExpr pos e
  emit $ JMP lblEnd
  emit $ LABEL lblThen
  compileExpr pos t
  emit $ LABEL lblEnd

compileExpr pos (Form f args) =
  ask <&> envArity <&> Map.lookup f >>= \case
    Just arity
      | length args /= arity
      -> throw $ show f ++ " requires " ++ show arity ++ " arguments, "
          ++ show (length args) ++ " given"

      | Tail origArity <- pos
      -> do
        -- if we're in the tail position, we must have an empty local stack, too

        -- resize the activation record
        when (arity /= origArity) $ do
          -- move stored PC
          emit $ LLOAD 0
          emit $ LSTORE (origArity - arity)

          -- move stored BP
          emit $ LLOAD 1
          emit $ LSTORE (origArity - arity - 1)

          -- increment BP
          emit $ LOAD addrBP 0
          emit $ OP 0 (XInt $ arity - origArity)
          emit $ STORE addrBP 0

          -- set SP to BP
          emit $ LOAD addrBP 0
          emit $ STORE addrSP 0

        -- overwrite the args
        for_ (zip [0..] args) $ \(i, arg) -> do
          compileExpr NonTail arg
          emit $ LSTORE (1 + arity - i)

        -- tail call!
        emit $ JMP f

      | otherwise -> do
        emit $ OP 0 (XStr "ret")  -- return value
        traverse_ (compileExpr NonTail) args  -- args

        -- push activation record
        retLabel <- freshLabel -- a new label
        emit $ LOAD addrBP 0  -- save BP
        emit $ PUSHL retLabel  -- save PC

        -- set the base pointer to the stack pointer
        emit $ LOAD  addrSP 0
        emit $ STORE addrBP 0

        emit $ JMP f
        -- now the called function takes over
        -- it will pop the PC and jump to it
        emit $ LABEL retLabel

        -- restore the base pointer
        emit $ STORE addrBP 0
        emit $ POP (length args)

        -- leave the return value on the stack

    Nothing -> throw $ "unknown form: " ++ show f

withScope :: Def -> CG a -> CG a
withScope def = local $
  \env -> env{ envScope = def : envScope env }

runCG :: Env -> State -> CG () -> Either String (Code String)
runCG env st cg =
  fmap snd $
    runExcept $
      evalRWST cg env st

compileDef :: Def -> CG ()
compileDef def = do
  emit $ LABEL (defName def)
  withScope def $
    compileExpr (Tail arity) (Form "begin" $ defBody def)
  emit $ LSTORE (2 + arity)
  emit $ RET
 where
  arity = length (defArgs def)

compile :: [Def] -> Either String (Code String)
compile defs = runCG env st $
  case lookup "main" [(defName d, d) | d <- defs] of
    Nothing -> throw $ "could not find main"
    Just main -> do
      traverse_ (compileExpr NonTail) (defBody main) -- no TCO here because we don't have an activation record
      emit $ HALT
      traverse_ compileDef [d | d <- defs, defName d /= "main"]
  where
    st = State
      { stFreshLabels = 0
      }
    env = Env
      { envScope = []
      , envArity = Map.fromList [(defName d, length $ defArgs d) | d <- defs]
      }

resolve :: forall a. (Eq a, Ord a, Show a) => Code a -> Either String (Code PC)
resolve code = traverse go code
  where
    go :: Instr a -> Either String (Instr PC)
    go = \case
      LOAD addr ofs -> pure $ LOAD addr ofs
      STORE addr ofs -> pure $ STORE addr ofs
      LLOAD ofs -> pure $ LLOAD ofs
      LSTORE ofs -> pure $ LSTORE ofs
      OP n xe -> pure $ OP n xe
      POP n -> pure $ POP n
      PUSHL lbl -> PUSHL <$> getL lbl
      PRINT -> pure $ PRINT
      LABEL lbl -> LABEL <$> getL lbl
      JMP lbl -> JMP <$> getL lbl
      JZ lbl -> JZ <$> getL lbl
      JNEG lbl -> JNEG <$> getL lbl
      RET -> pure RET
      HALT -> pure HALT

    getL :: a -> Either String PC
    getL lbl = case Map.lookup lbl labels of
      Nothing   -> Left $ "label not found: " ++ show lbl
      Just addr -> Right addr

    labels :: Map a PC
    labels = Map.fromList [(lbl, PC i) | (i, LABEL lbl) <- zip [0..] code]
