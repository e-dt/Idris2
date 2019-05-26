module TTImp.ProcessType

import Core.Context
import Core.Core
import Core.Env
import Core.Normalise
import Core.TT
import Core.UnifyState
import Core.Value

import TTImp.Elab.Check
import TTImp.Elab
import TTImp.TTImp

getRetTy : Defs -> NF [] -> Core Name
getRetTy defs (NBind fc _ (Pi _ _ _) sc)
    = getRetTy defs !(sc defs (toClosure defaultOpts [] (Erased fc)))
getRetTy defs (NTCon _ n _ _ _) = pure n
getRetTy defs ty
    = throw (GenericMsg (getLoc ty) 
             "Can only add hints for concrete return types")

processFnOpt : {auto c : Ref Ctxt Defs} ->
               FC -> Name -> FnOpt -> Core ()
processFnOpt fc ndef Inline 
    = setFlag fc ndef Inline
processFnOpt fc ndef (Hint d)
    = do defs <- get Ctxt
         Just ty <- lookupTyExact ndef (gamma defs)
              | Nothing => throw (UndefinedName fc ndef)
         target <- getRetTy defs !(nf defs [] ty)
         addHintFor fc target ndef d
processFnOpt fc ndef (GlobalHint a)
    = addGlobalHint ndef a
processFnOpt fc ndef ExternFn
    = setFlag fc ndef Inline -- if externally defined, inline when compiling
processFnOpt fc ndef Invertible
    = setFlag fc ndef Invertible
processFnOpt fc ndef Total
    = setFlag fc ndef (SetTotal Total)
processFnOpt fc ndef Covering
    = setFlag fc ndef (SetTotal CoveringOnly)
processFnOpt fc ndef PartialOK
    = setFlag fc ndef (SetTotal PartialOK)

export
processType : {vars : _} ->
              {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              List ElabOpt -> NestedNames vars -> Env Term vars -> 
              FC -> RigCount -> Visibility ->
              List FnOpt -> ImpTy -> Core ()
processType eopts nest env fc rig vis opts (MkImpTy tfc n_in ty_raw)
    = do n <- inCurrentNS n_in
         log 1 $ "Processing " ++ show n
         log 5 $ "Checking type decl " ++ show n ++ " : " ++ show ty_raw
         idx <- resolveName n 
         
         (ty, _, _) <- elabTerm idx InType (HolesOkay :: eopts) nest env 
                             (IBindHere fc (PI Rig0) ty_raw) 
                             (Just (gType fc))
         logTermNF 5 (show n) [] (abstractEnvType tfc env ty)
         -- TODO: Check name visibility
         let def = None -- TODO: External definitions

         addDef (Resolved idx) (newDef fc n rig (abstractEnvType tfc env ty) vis def)
         -- Flag it as checked, because we're going to check the clauses 
         -- from the top level.
         -- But, if it's a case block, it'll be checked as part of the top
         -- level check so don't set the flag.
         when (not (InCase `elem` eopts)) $ setLinearCheck idx True

         log 1 $ "Setting options for " ++ show n ++ ": " ++ show opts
         traverse (processFnOpt fc (Resolved idx)) opts

         -- TODO: Interface hash and saving
         pure ()