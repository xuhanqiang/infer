(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
module F = Format
module L = Logging

(** backward analysis for computing set of maybe-live variables at each program point *)

module Domain = AbstractDomain.FiniteSet (Var)

(* compilers 101-style backward transfer functions for liveness analysis. gen a variable when it is
   read, kill the variable when it is assigned *)
module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = Domain

  type extras = ProcData.no_extras

  (* add all of the vars read in [exp] to the live set *)
  let exp_add_live exp astate =
    let ids, pvars = Exp.get_vars exp in
    let astate' =
      List.fold ~f:(fun astate_acc id -> Domain.add (Var.of_id id) astate_acc) ~init:astate ids
    in
    List.fold
      ~f:(fun astate_acc pvar -> Domain.add (Var.of_pvar pvar) astate_acc)
      ~init:astate' pvars


  let exec_instr astate _ _ = function
    | Sil.Load (lhs_id, rhs_exp, _, _) ->
        Domain.remove (Var.of_id lhs_id) astate |> exp_add_live rhs_exp
    | Sil.Store (Lvar lhs_pvar, _, rhs_exp, _) ->
        let astate' =
          if Pvar.is_global lhs_pvar then astate (* never kill globals *)
          else Domain.remove (Var.of_pvar lhs_pvar) astate
        in
        exp_add_live rhs_exp astate'
    | Sil.Store (lhs_exp, _, rhs_exp, _) ->
        exp_add_live lhs_exp astate |> exp_add_live rhs_exp
    | Sil.Prune (exp, _, _, _) ->
        exp_add_live exp astate
    | Sil.Call (ret_id, call_exp, params, _, _) ->
        Option.value_map
          ~f:(fun (ret_id, _) -> Domain.remove (Var.of_id ret_id) astate)
          ~default:astate ret_id
        |> exp_add_live call_exp
        |> fun x -> List.fold_right ~f:exp_add_live (List.map ~f:fst params) ~init:x
    | Sil.Declare_locals _ | Remove_temps _ | Abstract _ | Nullify _ ->
        astate

end

module CFG = ProcCfg.OneInstrPerNode (ProcCfg.Backward (ProcCfg.Exceptional))
module Analyzer = AbstractInterpreter.Make (CFG) (TransferFunctions)

let is_whitelisted_var var =
  let whitelisted_vars = ["__assert_file__"; "__assert_fn__"] in
  List.exists
    ~f:(fun whitelisted_var -> String.equal whitelisted_var (Pvar.get_simplified_name var))
    whitelisted_vars


let checker {Callbacks.tenv; summary; proc_desc} : Specs.summary =
  let cfg = CFG.from_pdesc proc_desc in
  let invariant_map =
    Analyzer.exec_cfg cfg (ProcData.make_default proc_desc tenv) ~initial:Domain.empty ~debug:true
  in
  (* we don't want to report in harmless cases like int i = 0; if (...) { i = ... } else { i = ... }
     that create an intentional dead store as an attempt to imitate default value semantics.
     use dead stores to a "sentinel" value as a heuristic for ignoring this case *)
  let is_sentinel_exp = function
    | Exp.Const Cint i ->
        IntLit.iszero i || IntLit.isnull i
    | Exp.Const Cfloat 0.0 ->
        true
    | _ ->
        false
  in
  let report_dead_store live_vars = function
    | Sil.Store (Lvar pvar, _, rhs_exp, loc)
      when not
             ( Pvar.is_frontend_tmp pvar || Pvar.is_return pvar || Pvar.is_global pvar
             || Domain.mem (Var.of_pvar pvar) live_vars || Procdesc.is_captured_var proc_desc pvar
             || is_whitelisted_var pvar || is_sentinel_exp rhs_exp ) ->
        let issue_id = IssueType.dead_store.unique_id in
        let message = F.asprintf "The value written to %a is never used" (Pvar.pp Pp.text) pvar in
        let ltr = [Errlog.make_trace_element 0 loc "Write of unused value" []] in
        let exn = Exceptions.Checkers (issue_id, Localise.verbatim_desc message) in
        Reporting.log_error summary ~loc ~ltr exn
    | _ ->
        ()
  in
  let report_on_node node =
    List.iter (CFG.instr_ids node) ~f:(fun (instr, node_id_opt) ->
        match node_id_opt with
        | Some node_id -> (
          match Analyzer.extract_pre node_id invariant_map with
          | Some live_vars ->
              report_dead_store live_vars instr
          | None ->
              () )
        | None ->
            () )
  in
  List.iter (CFG.nodes cfg) ~f:report_on_node ;
  summary

