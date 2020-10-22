module Xls where

import Bytecode

data XE
  = XEInt Int
  | XEStr String
  | XEAddr Addr
  | XERef XE
  | XEOp String XE XE
  | XEFun String [XE]
  deriving (Eq, Ord, Show)

type ICode = [(PC, Instr PC)]

toICode :: Code PC -> ICode
toICode = zip $ map PC [0..]

xeIf :: XE -> XE -> XE -> XE
xeIf c t e = XEFun "IF" [c, t, e]

xeEq :: XE -> XE -> XE
xeEq = XEOp "="

xeNot :: XE -> XE
xeNot c = XEFun "NOT" [c]

xeRef :: Addr -> XE
xeRef = XERef . XEAddr

xeRefOfs :: Addr -> Int -> XE
xeRefOfs addr ofs = XERef (xeInc ofs (xeRef addr))

xeIsTop :: Int -> Addr -> XE
xeIsTop 0 cellAddr =
  XEAddr cellAddr `xeEq` xeRef addrSP
xeIsTop ofs cellAddr =
  XEAddr cellAddr `xeEq` XEOp "-" (xeRef addrSP) (XEInt ofs)

xeCond :: Addr -> [(XE, XE)] -> XE
xeCond cellAddr [] = xeRef cellAddr
xeCond cellAddr ((cond, rhs):xs) =
  xeIf cond rhs $ xeCond cellAddr xs

xeInc :: Int -> XE -> XE
xeInc i = XEOp "+" (XEInt i)

xeLoc :: Int -> XE
xeLoc ofs = xeRefOfs addrBP (-ofs)

xeTop :: Int -> XE
xeTop ofs = xeRefOfs addrSP (-ofs)

xeXExpr :: XExpr -> XE
xeXExpr (XRef addr) = XEAddr addr
xeXExpr (XLoc ofs) = xeLoc ofs
xeXExpr (XTop ofs) = xeTop ofs
xeXExpr (XInt i) = XEInt i
xeXExpr (XStr s) = XEStr s
xeXExpr (XFun f args) = XEFun f (map xeXExpr args)
xeXExpr (XOp op x y) = XEOp op (xeXExpr x) (xeXExpr y)

xeInstr :: Addr -> Instr PC -> XE
xeInstr cellAddr = \case
  LOAD addr
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | cellAddr == addrSP -> xeInc 1 (xeRef addrSP)
    | otherwise -> xeCond cellAddr
      [ (xeIsTop 0 cellAddr, xeRef addr)
      ]
  STORE addr
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | cellAddr == addrSP -> xeInc (-1) (xeRef addrSP)
    | cellAddr == addr -> xeTop 0
    | otherwise -> xeCond cellAddr []

  LLOAD ofs
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | cellAddr == addrSP -> xeInc 1 (xeRef addrSP)
    | otherwise -> xeCond cellAddr
      [ (xeIsTop 0 cellAddr, xeLoc ofs)
      ]

  LSTORE ofs
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | cellAddr == addrSP -> xeInc (-1) (xeRef addrSP)
    | otherwise -> xeCond cellAddr
      [ ( XEAddr cellAddr `xeEq` xeInc (-ofs) (xeRef addrBP)
        , xeTop 0
        )
      ]

  OP n expr
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | cellAddr == addrSP -> xeInc (1-n) (xeRef addrSP)
    | otherwise -> xeCond cellAddr
      [ (xeIsTop (n-1) cellAddr, xeXExpr expr)
      ]

  POP n
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | cellAddr == addrSP -> xeInc (-n) (xeRef addrSP)
    | otherwise -> xeCond cellAddr []

  PUSHL (PC pc)
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | cellAddr == addrSP -> xeInc 1 (xeRef addrSP)
    | otherwise -> xeCond cellAddr
      [ (xeIsTop 0 cellAddr, XEInt pc)
      ]

  PRINT
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | cellAddr == addrOUT -> xeTop 0
    | otherwise -> xeCond cellAddr []

  LABEL _
    | cellAddr == addrPC -> xeInc 1 (xeRef addrPC)
    | otherwise -> xeCond cellAddr []

  JMP (PC pc)
    | cellAddr == addrPC -> XEInt pc
    | otherwise -> xeCond cellAddr []

  JZ (PC pc)
    | cellAddr == addrPC ->
      xeIf (xeTop 0 `xeEq` XEInt 0)
        (XEInt pc)
        (xeInc 1 (xeRef addrPC))
    | otherwise -> xeCond cellAddr []

  JNEG (PC pc)
    | cellAddr == addrPC ->
      xeIf (XEOp "<" (xeTop 0) (XEInt 0))
        (XEInt pc)
        (xeInc 1 (xeRef addrPC))
    | otherwise -> xeCond cellAddr []

  RET
    | cellAddr == addrPC -> xeTop 0
    | cellAddr == addrSP -> xeInc (-1) (xeRef addrSP)
    | otherwise -> xeCond cellAddr []

  HALT -> xeCond cellAddr []  -- stay stuck here forever

xeCell :: ICode -> Addr -> XE
xeCell [] _ = error "empty code"
xeCell [(_, instr)] pos = xeInstr pos instr
xeCell code pos =
  case halve code of
    (PC pc, xs, ys) ->
      XEFun "IF"
        [ XEOp "<" (xeRef addrPC) (XEInt pc)
        , xeCell xs pos
        , xeCell ys pos
        ]

-- returns the first pc in the 2nd half
halve :: ICode -> (PC, ICode, ICode)
halve code =
  case splitAt (length code `div` 2) code of
    (xs, ys@((pc,_):_)) -> (pc, xs, ys)
    _ -> error $ "halve: bad input: " ++ show code
