module TTImp.Elab.Delayed

import Core.CaseTree
import Core.Context
import Core.Core
import Core.Env
import Core.Metadata
import Core.Normalise
import Core.Unify
import Core.TT
import Core.Value

import TTImp.Elab.Check
import TTImp.TTImp

import Data.IntMap

%default covering

-- We run the elaborator in the given environment, but need to end up with a
-- closed term.
mkClosedElab : FC -> Env Term vars ->
               (Core (Term vars, Glued vars)) ->
               Core ClosedTerm
mkClosedElab fc [] elab
    = do (tm, _) <- elab
         pure tm
mkClosedElab {vars = x :: vars} fc (b :: env) elab
    = mkClosedElab fc env
          (do (sc', _) <- elab
              let b' = newBinder b
              pure (Bind fc x b' sc', gErased fc))
  where
    -- in 'abstractEnvType' we get a Pi binder (so we'll need a Lambda) for
    -- everything except 'Let', so make the appropriate corresponding binder
    -- here
    newBinder : Binder (Term vars) -> Binder (Term vars)
    newBinder (Let c val ty) = Let c val ty
    newBinder b = Lam (multiplicity b) Explicit (binderType b)

-- Try the given elaborator; if it fails, and the error matches the
-- predicate, make a hole and try it again later when more holes might
-- have been resolved
export
delayOnFailure : {auto c : Ref Ctxt Defs} ->
                 {auto m : Ref MD Metadata} ->
                 {auto u : Ref UST UState} ->
                 {auto e : Ref EST (EState vars)} ->
                 FC -> RigCount -> Env Term vars ->
                 (expected : Glued vars) ->
                 (Error -> Bool) ->
                 (Bool -> Core (Term vars, Glued vars)) ->
                 Core (Term vars, Glued vars)
delayOnFailure fc rig env expected pred elab
    = do est <- get EST
         handle (elab (not (allowDelay est)))
          (\err =>
              do est <- get EST
                 if pred err && allowDelay est
                    then
                      do nm <- genName "delayed"
                         (ci, dtm) <- newDelayed fc Rig1 env nm !(getTerm expected)
                         logGlueNF 5 ("Postponing elaborator " ++ show nm ++
                                      " at " ++ show fc ++
                                      " for") env expected
                         log 10 ("Due to error " ++ show err)
                         ust <- get UST
                         put UST (record { delayedElab $=
                                 ((ci, mkClosedElab fc env (elab True)) :: ) }
                                         ust)
                         pure (dtm, expected)
                    else throw err)

export
delayElab : {auto c : Ref Ctxt Defs} ->
            {auto m : Ref MD Metadata} ->
            {auto u : Ref UST UState} ->
            {auto e : Ref EST (EState vars)} ->
            FC -> RigCount -> Env Term vars ->
            (expected : Maybe (Glued vars)) ->
            Core (Term vars, Glued vars) ->
            Core (Term vars, Glued vars)
delayElab {vars} fc rig env exp elab
    = do est <- get EST
         if not (allowDelay est)
            then elab
            else do
             nm <- genName "delayed"
             expected <- mkExpected exp
             (ci, dtm) <- newDelayed fc Rig1 env nm !(getTerm expected)
             logGlueNF 5 ("Postponing elaborator " ++ show nm ++
                          " for") env expected
             ust <- get UST
             put UST (record { delayedElab $=
                     ((ci, mkClosedElab fc env elab) :: ) }
                             ust)
             pure (dtm, expected)
  where
    mkExpected : Maybe (Glued vars) -> Core (Glued vars)
    mkExpected (Just ty) = pure ty
    mkExpected Nothing
        = do nm <- genName "delayTy"
             ty <- metaVar fc Rig0 env nm (TType fc)
             pure (gnf env ty)

export
retryDelayed : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST UState} ->
               {auto e : Ref EST (EState vars)} ->
               List (Int, Core ClosedTerm) ->
               Core ()
retryDelayed [] = pure ()
retryDelayed ((i, elab) :: ds)
    = do defs <- get Ctxt
         Just Delayed <- lookupDefExact (Resolved i) (gamma defs)
              | _ => retryDelayed ds
         log 5 ("Retrying delayed hole " ++ show !(getFullName (Resolved i)))
         -- elab itself might have delays internally, so keep track of them
         ust <- get UST
         put UST (record { delayedElab = [] } ust)
         tm <- elab
         ust <- get UST
         let ds' = reverse (delayedElab ust) ++ ds

         updateDef (Resolved i) (const (Just
              (PMDef (MkPMDefInfo NotHole True) [] (STerm tm) (STerm tm) [])))
         logTerm 5 ("Resolved delayed hole " ++ show i) tm
         logTermNF 5 ("Resolved delayed hole NF " ++ show i) [] tm
         removeHole i
         retryDelayed ds'

-- Run an elaborator, then all the delayed elaborators arising from it
export
runDelays : {auto c : Ref Ctxt Defs} ->
            {auto u : Ref UST UState} ->
            {auto e : Ref EST (EState vars)} ->
            Core a -> Core a
runDelays elab
    = do ust <- get UST
         let olddelayed = delayedElab ust
         put UST (record { delayedElab = [] } ust)
         tm <- elab
         ust <- get UST
         catch (retryDelayed (reverse (delayedElab ust)))
               (\err =>
                  do ust <- get UST
                     put UST (record { delayedElab = olddelayed } ust)
                     throw err)
         ust <- get UST
         put UST (record { delayedElab = olddelayed } ust)
         pure tm
