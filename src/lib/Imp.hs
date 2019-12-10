-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Imp (impPass, checkImp) where

import Control.Monad.Reader
import Data.Foldable
import Data.List (zip4)

import Syntax
import Env
import Type
import PPrint
import Pass
import Cat
import Record
import Util
import Fresh

data Dest = Buffer Name [Index]
type ImpEnv = (Env IExpr, Env ())
type ImpM a = ReaderT ImpEnv (Either Err) a

impPass :: TopPass NTopDecl ImpDecl
impPass = TopPass $ \decl -> case decl of
  NTopDecl _ decl' -> do
    (bs, prog, env) <- liftTop $ toImpDecl decl'
    extend env
    return $ ImpTopLet bs prog
  NRuleDef _ _ _ -> error "Shouldn't have this left"
  NEvalCmd (Command cmd (ty, ts, expr)) -> do
    ts' <- liftTop $ mapM toImpType ts
    let bs = [Name "%imptmp" i :> t | (i, t) <- zip [0..] ts']
    prog <- liftTop $ toImp (map asDest bs) expr
    case cmd of
      ShowImp -> emitOutput $ TextOut $ pprint prog
      _ -> return $ ImpEvalCmd (reconstruct ty) bs (Command cmd prog)
  where
    liftTop :: ImpM a -> TopPassM ImpEnv a
    liftTop m = do
      env <- look
      liftExceptTop $ runReaderT m env

toImp :: [Dest] -> NExpr -> ImpM ImpProg
toImp dests expr = case expr of
  NDecl decl body -> do
    (bs, bound', env) <- toImpDecl decl
    body' <- extendR env $ toImp dests body
    return $ wrapAllocs bs $ bound' <> body'
  NScan ib@(_:>n) bs xs body -> do
    ~([i:>_], idxEnv ) <- toImpBinders [ib]
    xs' <- mapM toImpAtom xs
    n' <- typeToSize n
    bs' <- mapM toImpBinder bs
    let (carryOutDests, mapDests) = splitAt (length bs) dests
    let initProg = fold $ zipWith copy carryOutDests xs'
    loopProg <- withAlloc bs' $ \carryTmpDests carryTmpVals -> do
       let copyToTmp = fold $ zipWith copy carryTmpDests (map destAsIExpr carryOutDests)
       body' <- extendR (idxEnv <> bindEnv bs' carryTmpVals) $
         toImp (carryOutDests ++ map (indexDest (IVar i)) mapDests) $ body
       return $ ImpProg [Loop i n' (copyToTmp <> body')]
    return $ initProg <> loopProg
  NPrimOp b ts xs -> do
    ts' <- mapM toImpType (concat ts)
    xs' <- mapM toImpAtom xs
    return $ toImpPrimOp b dests ts' xs'
  NAtoms xs -> do
    xs' <- mapM toImpAtom xs
    return $ fold $ zipWith copy dests xs'
  NTabCon _ _ rows -> do
    liftM fold $ zipWithM writeRow [0..] rows
    where writeRow i row = toImp (indexedDests i) row
          indexedDests i = map (indexDest (ILit (IntLit i))) dests
  NApp _ _ -> error "NApp should be gone by now"

bindEnv :: [BinderP a] -> [IExpr] -> ImpEnv
bindEnv bs xs = asFst $ fold $ zipWith (\(v:>_) x -> v @> x) bs xs

toImpDecl :: NDecl -> ImpM ([IBinder], ImpProg, ImpEnv)
toImpDecl decl = case decl of
  NLet bs expr -> do
    (bs', env) <- toImpBinders bs
    expr' <- extendR env $ toImp (map asDest bs') expr
    return (bs', expr', env)
  NUnpack nbs tv expr -> do
    (bs , env ) <- toImpBinders [tv :> NBaseType IntType]
    (bs', env') <- extendR env $ toImpBinders nbs
    let bs'' = bs ++ bs'
        env'' = env <> env'
    expr' <- extendR env'' $ toImp (map asDest bs'') expr
    return (bs'', expr', env'')

toImpBinders :: [NBinder] -> ImpM ([IBinder], ImpEnv)
toImpBinders bs = do
  (vs', scope) <- asks $ renames vs . snd
  ts' <- mapM toImpType ts
  let env = (fold $ zipWith (\v v' -> v @> IVar v') vs vs', scope)
  return (zipWith (:>) vs' ts', env)
  where (vs, ts) = unzip [(v, t) | v:>t <- bs]

toImpBinder :: NBinder -> ImpM IBinder
toImpBinder (v:>ty) = liftM (v:>) (toImpType ty)

withAlloc :: [IBinder] -> ([Dest] -> [IExpr] -> ImpM ImpProg) -> ImpM ImpProg
withAlloc bs body = do
  let (vs, ts) = unzip [(v, t) | v:>t <- bs]
  (vs', scope) <- asks $ renames vs . snd
  let bs' = zipWith (:>) vs' ts
  prog <- extendR (asSnd scope) $ body (map asDest bs') (map IVar vs')
  return $ wrapAllocs bs' prog

toImpAtom :: NAtom -> ImpM IExpr
toImpAtom atom = case atom of
  NLit x -> return $ ILit x
  NVar v -> lookupVar v
  NGet e i -> liftM2 IGet (toImpAtom e) (toImpAtom i)
  _ -> error $ "Not implemented: " ++ pprint atom

toImpPrimOp :: Builtin -> [Dest] -> [IType] -> [IExpr] -> ImpProg
toImpPrimOp Range      (dest:_) _ [x] = copy dest x
toImpPrimOp IndexAsInt [dest]   _ [x] = copy dest x
toImpPrimOp IntAsIndex [dest]   _ [x] = copy dest x  -- TODO: mod n
toImpPrimOp Select dests ts (p:args) =
  fold $ [ImpProg [Update name idxs Select [t] [p,x,y]] |
           (x, y, (Buffer name idxs), t) <- zip4 xs ys dests ts]
  where (xs, ys) = splitAt (length ts) args
toImpPrimOp b [Buffer name idxs] ts xs = ImpProg [Update name idxs b ts xs]
toImpPrimOp b dests _ _ = error $
  "Unexpected number of dests: " ++ show (length dests) ++ pprint b

toImpType :: NType -> ImpM IType
toImpType ty = case ty of
  NBaseType b -> return $ IType b []
  NTabType a b -> liftM2 addIdx (typeToSize a) (toImpType b)
  -- TODO: fix this (only works for range)
  NExists [] -> return intTy
  NTypeVar _ -> return intTy
  NIdxSetLit _ -> return intTy
  _ -> error $ "Can't lower type to imp: " ++ pprint ty

lookupVar :: Name -> ImpM IExpr
lookupVar v = do
  x <- asks $ flip envLookup v . fst
  return $ case x of
    Nothing -> IVar v
    Just v' -> v'

addIdx :: Size -> IType -> IType
addIdx n (IType ty shape) = IType ty (n : shape)

typeToSize :: NType -> ImpM IExpr
typeToSize (NTypeVar v) = lookupVar v
typeToSize (NIdxSetLit n) = return $ ILit (IntLit n)
typeToSize ty = error $ "Not implemented: " ++ pprint ty

asDest :: BinderP a -> Dest
asDest (v:>_) = Buffer v []

destAsIExpr :: Dest -> IExpr
destAsIExpr (Buffer v idxs) = foldl IGet (IVar v) idxs

indexDest :: Index -> Dest -> Dest
indexDest i (Buffer v destIdxs) = Buffer v (destIdxs `snoc` i)

snoc :: [a] -> a -> [a]
snoc xs x = reverse $ x : reverse xs

wrapAllocs :: [IBinder] -> ImpProg -> ImpProg
wrapAllocs [] prog = prog
wrapAllocs (b:bs) prog = ImpProg [Alloc b (wrapAllocs bs prog)]

-- TODO: copy should probably take a type argument
copy :: Dest -> IExpr -> ImpProg
copy (Buffer v idxs) x = ImpProg [Update v idxs Copy [] [x]]

intTy :: IType
intTy = IType IntType []

reconstruct :: Type -> Env Int -> [Vec] -> Value
reconstruct ty tenv vecs = Value (subty ty) $ restructure vecs (typeLeaves ty)
  where
    typeLeaves :: Type -> RecTree ()
    typeLeaves t = case t of
      BaseType _ -> RecLeaf ()
      TabType _ valTy -> typeLeaves valTy
      RecType _ r -> RecTree $ fmap typeLeaves r
      IdxSetLit _ -> RecLeaf ()
      _ -> error $ "can't show " ++ pprint t
    subty :: Type -> Type
    subty t = case t of
      BaseType _ -> t
      TabType (TypeVar v) valTy -> TabType (IdxSetLit (tenv ! v)) (subty valTy)
      TabType n valTy -> TabType n (subty valTy)
      RecType k r -> RecType k $ fmap subty r
      IdxSetLit _ -> t
      _ -> error $ "can't show " ++ pprint t

-- === type checking imp programs ===

type ImpCheckM a = ReaderT (Env IType) (Either Err) a

checkImp :: TopPass ImpDecl ImpDecl
checkImp = TopPass checkImp'

checkImp' :: ImpDecl -> TopPassM (Env IType) ImpDecl
checkImp' decl = decl <$ case decl of
  ImpTopLet binders prog -> do
    check binders prog
    extend $ bindFold binders
  ImpEvalCmd _ bs (Command _ prog) -> check bs prog
  where
    check :: [IBinder] -> ImpProg -> TopPassM (Env IType) ()
    check bs prog = do
      env <- look
      liftExceptTop $ addContext (pprint prog) $
         runReaderT (checkProg prog) (env <> bindFold bs)

checkProg :: ImpProg -> ImpCheckM ()
checkProg (ImpProg statements) = mapM_ checkStatement statements

checkStatement :: Statement -> ImpCheckM ()
checkStatement statement = case statement of
  Alloc b body -> do
    env <- ask
    if binderVar b `isin` env then throw CompilerErr $ "shadows:" ++ pprint b
                              else return ()
    extendR (bind b) (checkProg body)
  Update v idxs Copy [] [expr] -> do
    mapM_ checkInt idxs
    IType b  shape  <- asks $ (! v)
    IType b' shape' <- impExprType expr
    assertEq b b' "Base type mismatch in copy"
    assertEq (drop (length idxs) shape) shape' "Dimension mismatch"
  Update _ _ (FFICall _ _) _ _ -> return () -- TODO: check polymorphic builtins
  Update _ _ Select        _ _ -> return () -- TODO: ^
  Update v idxs builtin _ args -> do -- scalar builtins only for now
    argTys <- mapM impExprType args
    let BuiltinType _ _ inTys retTy = builtinType builtin
    zipWithM_ checkScalarTy inTys argTys
    IType b' shape  <- asks $ (! v)
    case drop (length idxs) shape of
      [] -> assertEq retTy (BaseType b') "Base type mismatch in builtin application"
      _  -> throw CompilerErr "Writing to non-scalar buffer"
  Loop i size block -> extendR (i @> intTy) $ do
                          checkInt size
                          checkProg block

impExprType :: IExpr -> ImpCheckM IType
impExprType expr = case expr of
  ILit val -> return $ IType (litType val) []
  IVar v   -> asks $ (! v)
  IGet e i -> do ~(IType b (_:shape)) <- impExprType e
                 checkInt i
                 return $ IType b shape

checkScalarTy :: Type -> IType -> ImpCheckM ()
checkScalarTy (BaseType b) (IType b' []) | b == b'= return ()
checkScalarTy ty ity = throw CompilerErr $ "Wrong types. Expected:" ++ pprint ty
                                                         ++ " Got " ++ pprint ity

checkInt :: IExpr -> ImpCheckM ()
checkInt expr = do
  ty <- impExprType expr
  assertEq (IType IntType []) ty $ "No an int: " ++ pprint expr