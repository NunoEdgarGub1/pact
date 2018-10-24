{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE TypeFamilies        #-}

module Pact.Analyze.Model.Text
  ( showModel
  ) where

import           Control.Lens               (Lens', at, ifoldr, view, (^.))
import           Control.Monad.State.Strict (State, evalState, get, modify)
import qualified Data.Foldable              as Foldable
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Monoid                ((<>))
import           Data.SBV                   (SBV, SymWord)
import qualified Data.SBV                   as SBV
import qualified Data.SBV.Internals         as SBVI
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           GHC.Natural                (Natural)

import qualified Pact.Types.Info            as Pact

import           Pact.Analyze.Model.Graph   (linearize)
import           Pact.Analyze.Types

indent1 :: Text -> Text
indent1 = ("  " <>)

indent :: Natural -> Text -> Text
indent 0     = id
indent times = indent (pred times) . indent1

showSbv :: (UserShow a, SymWord a) => SBV a -> Text
showSbv sbv = maybe "[ERROR:symbolic]" userShow (SBV.unliteral sbv)

showS :: (UserShow a, SymWord a) => S a -> Text
showS = showSbv . _sSbv

showTVal :: TVal -> Text
showTVal (ety, av) = case av of
  OpaqueVal   -> "[opaque]"
  AnObj obj   -> showObject obj
  AVal _ sval -> case ety of
    EObjectTy _           -> error "showModel: impossible object type for AVal"
    EType (_ :: SingTy t) -> showSbv (SBVI.SBV sval :: SBV (Concrete t))

showObject :: Object -> Text
showObject (Object m) = "{ "
  <> T.intercalate ", "
       (ifoldr (\key val acc -> showObjMapping key val : acc) [] m)
  <> " }"

showObjMapping :: Text -> TVal -> Text
showObjMapping key val = key <> ": " <> showTVal val

showArg :: Located (Unmunged, TVal) -> Text
showArg (Located _ (Unmunged nm, tval)) = nm <> " = " <> showTVal tval

showVar :: Located (Unmunged, TVal) -> Text
showVar (Located _ (Unmunged nm, tval)) = nm <> " := " <> showTVal tval

--
-- TODO: this should display the table name
--
showRead :: Located Access -> Text
showRead (Located _ (Access srk obj)) = "read " <> showObject obj
                                     <> " for key " <> showS srk

--
-- TODO: this should display the table name
--
showWrite :: Located Access -> Text
showWrite (Located _ (Access srk obj)) = "write " <> showObject obj
                                      <> " to key " <> showS srk

showKsn :: S KeySetName -> Text
showKsn sKsn = case SBV.unliteral (_sSbv sKsn) of
  Nothing               -> "[unknown]"
  Just (KeySetName ksn) -> "'" <> ksn

showFailure :: Recoverability -> Text
showFailure = \case
  Recoverable _ -> "recovered from failure"
  Unrecoverable -> "failed"

showAssert :: Recoverability -> Located (SBV Bool) -> Text
showAssert recov (Located (Pact.Info mInfo) lsb) = case SBV.unliteral lsb of
    Nothing    -> "[ERROR:symbolic assert]"
    Just True  -> "satisfied assertion" <> context
    Just False -> showFailure recov <> " to satisfy assertion" <> context

  where
    context = maybe "" (\(Pact.Code code, _) -> ": " <> code) mInfo

showAuth :: Recoverability -> Maybe Provenance -> Located Authorization -> Text
showAuth recov mProv (_located -> Authorization srk sbool) =
  status <> " " <> ksDescription

  where
    status = case SBV.unliteral sbool of
      Nothing    -> "[ERROR:symbolic auth]"
      Just True  -> "satisfied"
      Just False -> showFailure recov <> " to satisfy"

    ks :: Text
    ks = showS srk

    ksDescription = case mProv of
      Nothing ->
        "unknown " <> ks
      Just (FromCell (OriginatingCell (TableName tn) (ColumnName cn) sRk _)) ->
        ks <> " from database at ("
          <> T.pack tn <> ", "
          <> "'" <> T.pack cn <> ", "
          <> showS sRk <> ")"
      Just (FromNamedKs sKsn) ->
        ks <> " named " <> showKsn sKsn
      Just (FromInput (Unmunged arg)) ->
        ks <> " from argument " <> arg

-- TODO: after factoring Location out of TraceEvent, include source locations
--       in trace
showEvent
  :: Map TagId Provenance
  -> ModelTags 'Concrete
  -> TraceEvent
  -> State Natural [Text]
showEvent ksProvs tags event = do
  lastDepth <- get
  fmap (fmap (indent lastDepth)) $
    case event of
      TraceRead (_located -> (tid, _)) ->
        pure [display mtReads tid showRead]
      TraceWrite (_located -> (tid, _)) ->
        pure [display mtWrites tid showWrite]
      TraceAssert recov (_located -> tid) ->
        pure [display mtAsserts tid (showAssert recov)]
      TraceAuth recov (_located -> tid) ->
        pure [display mtAuths tid (showAuth recov $ tid `Map.lookup` ksProvs)]
      TraceSubpathStart _ ->
        pure [] -- not shown to end-users
      TracePushScope _ scopeTy locatedBindings -> do
        let vids = view (located.bVid) <$> locatedBindings
        modify succ
        let displayVids show' =
              (\vid -> indent1 $ display mtVars vid show') <$> vids

        pure $ case scopeTy of
          LetScope ->
            "let" : displayVids showVar
          ObjectScope ->
            "destructuring object" : displayVids showVar
          FunctionScope nm ->
            let header = "entering function " <> nm
                      <> " with argument" <> if length vids > 1 then "s" else ""
            in header : (displayVids showArg ++ [emptyLine])
      TracePopScope _ scopeTy tid _ -> do
        modify pred
        pure $ case scopeTy of
          LetScope -> []
          ObjectScope -> []
          FunctionScope _ ->
            ["returning with " <> display mtReturns tid showTVal, emptyLine]

  where
    emptyLine :: Text
    emptyLine = ""

    display
      :: Ord k
      => Lens' (ModelTags 'Concrete) (Map k v)
      -> k
      -> (v -> Text)
      -> Text
    display l ident f = maybe "[ERROR:missing tag]" f $ tags ^. l.at ident

showModel :: Model 'Concrete -> Text
showModel model =
    T.intercalate "\n" $ T.intercalate "\n" . map indent1 <$>
      [ ["Arguments:"]
      , indent1 <$> Foldable.toList (showArg <$> (model ^. modelArgs))
      , []
      , ["Program trace:"]
      , indent1 <$> (concat $ evalState (traverse showEvent' traceEvents) 0)
      , []
      , ["Result:"]
      , [indent1 $ maybe
          "Transaction aborted."
          (\tval -> "Return value: " <> showTVal tval)
          mRetval
        ]
      ]

  where
    ExecutionTrace traceEvents mRetval = linearize model

    showEvent' = showEvent (model ^. modelKsProvs) (model ^. modelTags)
