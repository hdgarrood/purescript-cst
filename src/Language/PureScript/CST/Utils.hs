module Language.PureScript.CST.Utils where

import Prelude

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Traversable (for)
import Language.PureScript.CST.Monad
import Language.PureScript.CST.Types

placeholder :: SourceToken
placeholder =
  ( TokenAnn (SourceRange (SourcePos 0 0) (SourcePos 0 0)) [] []
  , TokLowerName [] "<placeholder>"
  )

unexpected :: SourceToken -> Ident
unexpected tok = Ident tok [] "<unexpected>"

unexpectedExpr :: Monoid a => [SourceToken] -> Expr a
unexpectedExpr toks = ExprIdent mempty (unexpected (head toks))

unexpectedDecl :: Monoid a => [SourceToken] -> Declaration a
unexpectedDecl toks = DeclValue mempty (ValueBindingFields (unexpected (head toks)) [] (Guarded []))

unexpectedBinder :: Monoid a => [SourceToken] -> Binder a
unexpectedBinder toks = BinderVar mempty (unexpected (head toks))

unexpectedLetBinding :: Monoid a => [SourceToken] -> LetBinding a
unexpectedLetBinding toks = LetBindingName mempty (ValueBindingFields (unexpected (head toks)) [] (Guarded []))

unexpectedInstBinding :: Monoid a => [SourceToken] -> InstanceBinding a
unexpectedInstBinding toks = InstanceBindingName mempty (ValueBindingFields (unexpected (head toks)) [] (Guarded []))

separated :: [(SourceToken, a)] -> Separated a
separated = go []
  where
  go accum ((_, a) : []) = Separated a accum
  go accum (x : xs) = go (x : accum) xs
  go _ [] = internalError "Separated should not be empty"

consSeparated :: a -> SourceToken -> Separated a -> Separated a
consSeparated x sep (Separated {..}) = Separated x ((sep, sepHead) : sepTail)

internalError :: String -> a
internalError = error

toIdent :: SourceToken -> Ident
toIdent tok = case tok of
  (_, TokLowerName q a) -> Ident tok q a
  (_, TokUpperName q a) -> Ident tok q a
  (_, TokSymbol q a)    -> Ident tok q a
  (_, TokHole a)        -> Ident tok [] a
  _                     -> internalError $ "Invalid identifier token: " <> show tok

toVar :: SourceToken -> Parser Ident
toVar tok = case tok of
  (_, TokLowerName q a)
    | not (Set.member a reservedNames) -> pure $ Ident tok q a
    | otherwise -> parseFail tok ErrKeywordVar
  _ -> internalError $ "Invalid variable token: " <> show tok

toSymbol :: SourceToken -> Parser Ident
toSymbol tok = case tok of
  (_, TokSymbol q a)
    | not (Set.member a reservedSymbols) -> pure $ Ident tok q a
    | otherwise -> parseFail tok ErrKeywordSymbol
  _ -> internalError $ "Invalid operator token: " <> show tok

toLabel :: SourceToken -> Ident
toLabel tok = case tok of
  (_, TokLowerName [] a) -> Ident tok [] a
  (_, TokString _ a)     -> Ident tok [] a
  (_, TokRawString a)    -> Ident tok [] a
  _                      -> internalError $ "Invalid label: " <> show tok

labelToVar :: Ident -> Parser Ident
labelToVar (Ident tok _ _) = toVar tok

toString :: SourceToken -> (SourceToken, Text)
toString tok = case tok of
  (_, TokString _ a)  -> (tok, a)
  (_, TokRawString a) -> (tok, a)
  _                   -> internalError $ "Invalid string literal: " <> show tok

toChar :: SourceToken -> (SourceToken, Char)
toChar tok = case tok of
  (_, TokChar _ a) -> (tok, a)
  _                -> internalError $ "Invalid char literal: " <> show tok

toNumber :: SourceToken -> (SourceToken, Either Integer Double)
toNumber tok = case tok of
  (_, TokInt _ a)    -> (tok, Left a)
  (_, TokNumber _ a) -> (tok, Right a)
  _                  -> internalError $ "Invalid number literal: " <> show tok

toInt :: SourceToken -> (SourceToken, Integer)
toInt tok = case tok of
  (_, TokInt _ a)    -> (tok, a)
  _                  -> internalError $ "Invalid integer literal: " <> show tok

toBoolean :: SourceToken -> (SourceToken, Bool)
toBoolean tok = case tok of
  (_, TokLowerName [] "true")  -> (tok, True)
  (_, TokLowerName [] "false") -> (tok, False)
  _                            -> internalError $ "Invalid boolean literal: " <> show tok

toBinders :: forall a. Monoid a => Expr a -> Parser [Binder a]
toBinders = convert []
  where
  convert :: [Binder a] -> Expr a -> Parser [Binder a]
  convert acc = \case
    ExprSection a tok ->
      pure $ BinderWildcard a tok : acc
    ExprIdent a ident@(Ident _ [] _) ->
      pure $ BinderVar a ident : acc
    ExprConstructor a ident ->
      pure $ BinderConstructor a ident [] : acc
    ExprBoolean a tok val ->
      pure $ BinderBoolean a tok val : acc
    ExprChar a tok val ->
      pure $ BinderChar a tok val : acc
    ExprString a tok val ->
      pure $ BinderString a tok val : acc
    ExprNumber a tok val ->
      pure $ BinderNumber a Nothing tok val : acc
    ExprArray a del -> do
      del' <- traverse (traverse (traverse toBinder)) del
      pure $ BinderArray a del' : acc
    ExprRecord a del -> do
      del' <- traverse (traverse (traverse (traverse toBinder))) del
      pure $ BinderRecord a del' : acc
    ExprParens a wrap -> do
      wrap' <- traverse toBinder wrap
      pure $ BinderParens a wrap' : acc
    ExprTyped a expr tok ty -> do
      expr' <- toBinder expr
      pure $ BinderTyped a expr' tok ty : acc
    ExprOp a lhs op@(Ident tok [] "@") rhs ->
      case lhs of
        ExprIdent a' ident -> do
          rhs' <- toBinders rhs
          pure $ BinderNamed (a <> a') ident tok (head rhs') : tail rhs' <> acc
        ExprApp a' lhs' (ExprIdent a'' ident) -> do
          rhs' <- toBinders rhs
          convert (BinderNamed (a <> a' <> a'') ident tok (head rhs') : tail rhs' <> acc) lhs'
        ExprOp a' lhs' op' (ExprIdent a'' ident) -> do
          convert acc $ ExprOp a' lhs' op' (ExprOp a (ExprIdent a'' ident) op rhs)
        ExprOp a' lhs' op' (ExprApp a'' rhs'' (ExprIdent a''' ident)) -> do
          rhs' <- toBinders rhs
          convert (BinderNamed (a <> a'' <> a''') ident tok (head rhs') : tail rhs' <> acc) $ ExprOp a' lhs' op' rhs''
        _ -> parseFail (exprToken lhs) ErrExprInBinder
    ExprOp a lhs op rhs -> do
      lhs' <- toBinder lhs
      rhs' <- toBinder rhs
      pure $ BinderOp a lhs' op rhs' : acc
    ExprApp _ lhs rhs -> do
      rhs' <- toBinders rhs
      convert (rhs' <> acc) lhs
    expr -> parseFail (exprToken expr) ErrExprInBinder

toBinderAtoms :: forall a. Monoid a => Expr a -> Parser [Binder a]
toBinderAtoms expr = do
  bs <- toBinders expr
  for bs $ \b -> do
    let
      err = do
        let toks = [binderToken b]
        addFailure toks ErrExprInBinder
        pure $ unexpectedBinder toks
    case b of
      BinderOp {} -> err
      BinderTyped {} -> err
      _ -> pure b

toBinder :: forall a. Monoid a => Expr a -> Parser (Binder a)
toBinder expr = do
  bs <- toBinders expr
  case bs of
    BinderConstructor a ident [] : args -> pure $ BinderConstructor a ident args
    BinderNamed a ident tok (BinderConstructor a' ctr []) : args ->
      pure $ BinderNamed a ident tok $ BinderConstructor a' ctr args
    a : [] -> pure a
    _ : _ -> do
      let toks = binderToken <$> bs
      addFailure toks ErrExprInBinder
      pure $ unexpectedBinder toks
    [] -> internalError "Empty binder set"

toDeclOrBinder :: forall a. Monoid a => Expr a -> Parser (Either (a, Ident, [Binder a]) (Binder a))
toDeclOrBinder expr = do
  bs <- toBinders expr
  case bs of
    BinderVar a ident : args -> pure $ Left (a, ident, args)
    BinderConstructor a ident [] : args -> pure $ Right $ BinderConstructor a ident args
    a : [] -> pure $ Right $ a
    _ : _ -> do
      let toks = binderToken <$> bs
      addFailure toks ErrExprInDeclOrBinder
      pure $ Right $ unexpectedBinder toks
    [] -> internalError "Empty binder set"

toDecl
  :: forall a r
   . Monoid a
  => (a -> ValueBindingFields a -> r)
  -> ([SourceToken] -> r)
  -> Expr a
  -> Guarded a
  -> Parser r
toDecl ksucc kerr expr guarded = do
  bs <- toBinders expr
  case bs of
    BinderVar a ident : args -> pure $ ksucc a (ValueBindingFields ident args guarded)
    _ : _ -> do
      let toks = (binderToken <$> bs)
      addFailure toks ErrBinderInDecl
      pure $ kerr toks
    [] -> internalError "Empty binder set"

toRecordFields
  :: Separated (Either (RecordLabeled (Expr a)) (RecordUpdate a))
  -> Parser (Either (Separated (RecordLabeled (Expr a))) (Separated (RecordUpdate a)))
toRecordFields = \case
  Separated (Left a) as ->
    Left . Separated a <$> traverse (traverse unLeft) as
  Separated (Right a) as ->
    Right . Separated a <$> traverse (traverse unRight) as
  where
  unLeft (Left tok) = pure tok
  unLeft (Right tok) = parseFail (updateToken tok) ErrRecordUpdateInCtr

  unRight (Right tok) = pure tok
  unRight (Left (RecordPun (Ident tok _ _))) = parseFail tok ErrRecordPunInUpdate
  unRight (Left (RecordField _ tok _)) = parseFail tok ErrRecordCtrInUpdate

data TmpModuleDecl a
  = TmpImport (ImportDecl a)
  | TmpDecl (Declaration a)
  | TmpChain SourceToken (Declaration a)

toModuleDecls :: Monoid a => [TmpModuleDecl a] -> Parser ([ImportDecl a], [Declaration a])
toModuleDecls = goImport []
  where
  goImport acc (TmpImport x : xs) = goImport (x : acc) xs
  goImport acc xs = (reverse acc,) <$> goDecl [] xs

  goDecl acc [] = pure $ reverse acc
  goDecl acc (TmpDecl x : xs) = goDecl (x : acc) xs
  goDecl (DeclInstanceChain a (Separated h t) : acc) (TmpChain tok (DeclInstanceChain a' (Separated h' t')) : xs) =
    goDecl (DeclInstanceChain (a <> a') (Separated h (t <> ((tok, h') : t'))) : acc) xs
  goDecl _ (TmpChain tok _ : _) = parseFail tok ErrElseInDecl
  goDecl _ (TmpImport imp : _) = parseFail (impKeyword imp) ErrImportInDecl

varToType :: Monoid a => TypeVarBinding a -> Type a
varToType (TypeVarKinded (Wrapped l (Labeled var tok kind) r)) =
  TypeParens mempty
    (Wrapped l
      (TypeKinded mempty
        (TypeVar mempty var) tok kind) r)
varToType (TypeVarName ident) =
  TypeVar mempty ident

toLetBinding :: Monoid a => Expr a -> Guarded a -> Parser (LetBinding a)
toLetBinding lhs guarded = do
  b <- toDeclOrBinder lhs
  case b of
    Left (ann, ident, binders) ->
      pure $ LetBindingName ann (ValueBindingFields ident binders guarded)
    Right binder ->
      case guarded of
        Unconditional tok expr ->
          pure $ LetBindingPattern mempty binder tok expr
        Guarded (g : _) ->
          parseFail (grdBar g) ErrGuardInLetBinder
        Guarded _ ->
          internalError "Empty guard set"

reservedNames :: Set Text
reservedNames = Set.fromList
  [ "ado"
  , "case"
  , "class"
  , "data"
  , "derive"
  , "do"
  , "else"
  , "false"
  , "forall"
  , "foreign"
  , "import"
  , "if"
  , "in"
  , "infix"
  , "infixl"
  , "infixr"
  , "instance"
  , "let"
  , "module"
  , "newtype"
  , "of"
  , "true"
  , "type"
  , "where"
  ]

reservedSymbols :: Set Text
reservedSymbols = Set.fromList
  [ "∀"
  ]

exprToken :: Expr a -> SourceToken
exprToken = \case
  ExprHole _ a -> identTok a
  ExprSection _ a -> a
  ExprIdent _ a -> identTok a
  ExprConstructor _ a -> identTok a
  ExprBoolean _ a _ -> a
  ExprChar _ a _ -> a
  ExprString _ a _ -> a
  ExprNumber _ a _ -> a
  ExprArray _ a -> wrpOpen a
  ExprRecord _ a -> wrpOpen a
  ExprParens _ a -> wrpOpen a
  ExprTyped _ a _ _ -> exprToken a
  ExprInfix _ a _ _ -> exprToken a
  ExprOp _ a _ _ -> exprToken a
  ExprOpName _ a -> wrpOpen a
  ExprNegate _ a _ -> a
  ExprRecordAccessor _ a -> exprToken $ recExpr a
  ExprRecordUpdate _ a _ -> exprToken a
  ExprApp _ a _ -> exprToken a
  ExprLambda _ a -> lmbSymbol a
  ExprIf _ a -> iteIf a
  ExprCase _ a -> caseKeyword a
  ExprLet _ a -> letKeyword a
  ExprWhere _ a -> exprToken $ whereBody a
  ExprDo _ a -> doKeyword a
  ExprAdo _ a -> adoKeyword a

binderToken :: Binder a -> SourceToken
binderToken = \case
  BinderWildcard _ a -> a
  BinderVar _ a -> identTok a
  BinderNamed _ a _ _ -> identTok a
  BinderConstructor _ a _ -> identTok a
  BinderBoolean _ a _ -> a
  BinderChar _ a _ -> a
  BinderString _ a _ -> a
  BinderNumber _ mba a _ -> maybe a id mba
  BinderArray _ a -> wrpOpen a
  BinderRecord _ a -> wrpOpen a
  BinderParens _ a -> wrpOpen a
  BinderTyped _ a _ _ -> binderToken a
  BinderOp _ a _ _ -> binderToken a

updateToken :: RecordUpdate a -> SourceToken
updateToken = \case
  RecordUpdateLeaf a _ _ -> identTok a
  RecordUpdateBranch a _ -> identTok a
