{-# LANGUAGE CPP                   #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE DataKinds             #-}
{-# options_ghc -fno-warn-orphans #-}

module Pact.Analyze.PrenexNormalize (prenexConvert) where

import           Data.Bifunctor     (bimap)
import           Prelude            hiding (Float)

import           Pact.Analyze.Types
import           Pact.Analyze.Util

-- Note: pattern match shortcomings
--
-- Unfortunately, the version of GHC we're using doesn't support the COMPLETE
-- pragma to mark a set of pattern synonyms as complete. Because of this, we
-- forgo pattern synonyms on the left-hand-side, resulting in some unfortunate
-- patterns, like `CoreProp (Numerical (IntArithOp op a b))` (as compared to
-- `PIntArithOp op a b`).
--
-- Also, in several places we need to mark a `Numerical` pattern as vacuous,
-- for reasons that elude me.

#define STANDARD_INSTANCES                                            \
  PropSpecific Result -> ([], p);                                     \
  CoreProp Var{}      -> ([], p);                                     \
  CoreProp Lit{}      -> ([], p);                                     \
  CoreProp Sym{}      -> ([], p);                                     \
  CoreProp (ObjAt schema a b ty) -> PObjAt schema a <$> float b <*> pure ty;

instance Float 'TyInteger where
  float = floatIntegerQuantifiers

instance Float 'TyBool where
  float = floatBoolQuantifiers

instance Float 'TyDecimal where
  float = floatDecimalQuantifiers

instance Float 'TyStr where
  float = floatStringQuantifiers

instance Float 'TyTime where
  float = floatTimeQuantifiers

instance Float 'TyObject where
  float p = case p of
    STANDARD_INSTANCES
    CoreProp Numerical{} -> vacuousMatch "numerical can't be Object"
    CoreProp LiteralObject{} -> ([], p)
    CoreProp ObjectMerge{} -> ([], p)

instance Float 'TyKeySet where
  float p = case p of
    STANDARD_INSTANCES
    CoreProp Numerical{} -> vacuousMatch "numerical can't be KeySet"

instance Float 'TyAny where
  float p = case p of
    STANDARD_INSTANCES
    CoreProp Numerical{} -> vacuousMatch "numerical can't be Any"

flipQuantifier :: Quantifier -> Quantifier
flipQuantifier = \case
  Forall' uid name ty -> Exists' uid name ty
  Exists' uid name ty -> Forall' uid name ty

floatIntegerQuantifiers :: Prop 'TyInteger -> ([Quantifier], Prop 'TyInteger)
floatIntegerQuantifiers p = case p of
  STANDARD_INSTANCES

  CoreProp (StrLength pStr) -> PStrLength <$> float pStr

  CoreProp (Numerical (IntArithOp op a b))
    -> PNumerical ... IntArithOp      op <$> float a <*> float b
  CoreProp (Numerical (IntUnaryArithOp op a))
    -> PNumerical .   IntUnaryArithOp op <$> float a
  CoreProp (Numerical (ModOp a b))
    -> PNumerical ... ModOp              <$> float a <*> float b
  CoreProp (Numerical (RoundingLikeOp1 op a))
    -> PNumerical . RoundingLikeOp1 op   <$> float a
  PropSpecific (IntCellDelta tn cn a)
    -> PropSpecific . IntCellDelta tn cn <$> float a
  PropSpecific (RowWriteCount tn pRk)
    -> PropSpecific . RowWriteCount tn   <$> float pRk
  PropSpecific (RowReadCount tn pRk)
    -> PropSpecific . RowReadCount tn    <$> float pRk
  PropSpecific IntColumnDelta{} -> ([], p)

floatDecimalQuantifiers :: Prop 'TyDecimal -> ([Quantifier], Prop 'TyDecimal)
floatDecimalQuantifiers p = case p of
  STANDARD_INSTANCES
  CoreProp (Numerical (DecArithOp op a b))
    -> PNumerical ... DecArithOp      op <$> float a <*> float b
  CoreProp (Numerical (DecUnaryArithOp op a))
    -> PNumerical .   DecUnaryArithOp op <$> float a
  CoreProp (Numerical (DecIntArithOp op a b))
    -> PNumerical ... DecIntArithOp   op <$> float a <*> float b
  CoreProp (Numerical (IntDecArithOp op a b))
    -> PNumerical ... IntDecArithOp   op <$> float a <*> float b
  CoreProp (Numerical (RoundingLikeOp2 op a b))
    -> PNumerical ... RoundingLikeOp2 op <$> float a <*> float b
  PropSpecific (DecCellDelta tn cn a)
    -> PropSpecific . DecCellDelta tn cn  <$> float a
  PropSpecific DecColumnDelta{} -> ([], p)

floatStringQuantifiers :: Prop 'TyStr -> ([Quantifier], Prop 'TyStr)
floatStringQuantifiers p = case p of
  STANDARD_INSTANCES
  CoreProp Numerical{} -> vacuousMatch "numerical can't be String"
  CoreProp (StrConcat s1 s2) -> PStrConcat <$> float s1 <*> float s2

floatTimeQuantifiers :: Prop 'TyTime -> ([Quantifier], Prop 'TyTime)
floatTimeQuantifiers p = case p of
  STANDARD_INSTANCES
  CoreProp Numerical{} -> vacuousMatch "numerical can't be Time"
  CoreProp (IntAddTime time int) -> PIntAddTime <$> float time <*> float int
  CoreProp (DecAddTime time dec) -> PDecAddTime <$> float time <*> float dec

floatBoolQuantifiers :: Prop 'TyBool -> ([Quantifier], Prop 'TyBool)
floatBoolQuantifiers p = case p of
  STANDARD_INSTANCES

  CoreProp Numerical{} -> vacuousMatch "numerical can't be Bool"

  PropSpecific (Forall uid name ty prop) ->
    let (qs, prop') = float prop
    in (Forall' uid name ty:qs, prop')
  PropSpecific (Exists uid name ty prop) ->
    let (qs, prop') = float prop
    in (Exists' uid name ty:qs, prop')

  PropSpecific Abort              -> ([], p)
  PropSpecific Success            -> ([], p)
  PropSpecific TableWrite{}       -> ([], p)
  PropSpecific TableRead{}        -> ([], p)
  PropSpecific ColumnWritten{}    -> ([], p)
  PropSpecific ColumnRead{}       -> ([], p)
  PropSpecific KsNameAuthorized{} -> ([], p)
  PropSpecific RowEnforced{}      -> ([], p)

  CoreProp (IntegerComparison op a b)
    -> CoreProp ... IntegerComparison op <$> float a <*> float b
  CoreProp (DecimalComparison op a b)
    -> CoreProp ... DecimalComparison op <$> float a <*> float b
  CoreProp (TimeComparison op a b)
    -> CoreProp ... TimeComparison op <$> float a <*> float b
  CoreProp (StringComparison op a b)
    -> CoreProp ... StringComparison op <$> float a <*> float b
  CoreProp (BoolComparison op a b)
    -> CoreProp ... BoolComparison op <$> float a <*> float b
  CoreProp (ObjectEqNeq op a b) -> PObjectEqNeq op <$> float a <*> float b
  CoreProp (KeySetEqNeq op a b) -> PKeySetEqNeq op <$> float a <*> float b
  CoreProp (ListEqNeq   op (ESimple tyA a) (ESimple tyB b)) ->
    let -- HACK!
        qa = []
        qb = []
        a' = a
        b' = b
    -- let (qa, a') = float a
    --     (qb, b') = float b
    in (qa ++ qb, CoreProp (ListEqNeq op (ESimple tyA a') (ESimple tyB b')))

  PAnd a b     -> PAnd <$> float a <*> float b
  POr a b      -> POr  <$> float a <*> float b
  PNot a       -> bimap (fmap flipQuantifier) PNot (float a)
  CoreProp (Logical _ _) -> error ("ill-defined logical op: " ++ show p)

  PropSpecific (RowRead  tn pRk) -> PropSpecific . RowRead  tn <$> float pRk
  PropSpecific (RowWrite tn pRk) -> PropSpecific . RowWrite tn <$> float pRk

reassembleFloated :: [Quantifier] -> Prop 'TyBool -> Prop 'TyBool
reassembleFloated qs prop =
  let mkQuantifiedProp q acc = case q of
        Forall' uid name ty -> PropSpecific (Forall uid name ty acc)
        Exists' uid name ty -> PropSpecific (Exists uid name ty acc)
  in foldr mkQuantifiedProp prop qs

-- We first use @floatBoolQuantifiers@ to remove all quantifiers from the
-- @Prop@ (modifying them as necessary, then put them back in place on the
-- outside of the syntax tree.
--
-- The only interesting cases are those for @Forall@, @Exists@, and @PNot@. In
-- the first two cases, we capture the quantifier to float it up. In the @PNot@
-- case, we flip all the quantifiers found inside the @PNot@ as we lift them
-- over it.
prenexConvert :: Prop 'TyBool -> Prop 'TyBool
prenexConvert = uncurry reassembleFloated . floatBoolQuantifiers
