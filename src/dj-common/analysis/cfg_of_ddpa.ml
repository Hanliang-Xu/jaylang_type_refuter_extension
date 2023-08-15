open Core
open Jayil.Ast
open Ddpa
open Ddpa_abstract_ast
open Ddpa_graph
open Ddpa_helper
open Cfg

(* ddpa-unrelate cfg update, should move out *)

let update_clauses f block = { block with clauses = f block.clauses }

let update_id_dst id dst0 block =
  let add_dsts dst0 dsts =
    if List.mem dsts dst0 ~equal:Ident.equal then dsts else dst0 :: dsts
  in
  let add_dst_in_clause (tc : tl_clause) =
    if Ident.equal tc.id id
    then
      {
        tc with
        cat =
          (match tc.cat with
          | App dsts -> App (add_dsts dst0 dsts)
          | Cond dsts -> Cond (add_dsts dst0 dsts)
          | other -> other);
      }
    else tc
  in
  update_clauses (List.map ~f:add_dst_in_clause) block

let add_id_dst site_x def_x tl_map =
  let tl = find_block_by_id site_x tl_map in
  let tl' = update_id_dst site_x def_x tl in
  Ident_map.add tl.id tl' tl_map

(* ddpa-related cfg update*)

let make_cond_block_possible tl_map acls cfg =
  let cond_site, possible =
    match acls with
    | [
     Unannotated_clause (Abs_clause (Abs_var cond_site, Abs_conditional_body _));
     choice_clause;
    ] ->
        let choice = find_cond_choice choice_clause cfg in
        (cond_site, Some choice)
    | [
     Unannotated_clause (Abs_clause (Abs_var cond_site, Abs_conditional_body _));
     _clause1;
     _clause2;
    ] ->
        (cond_site, None)
    | _ -> failwith "wrong precondition to call"
  in
  let make_block_impossible block =
    let cond_block_info = cast_to_cond_block_info block in
    let cond_block_info' = { cond_block_info with possible = false } in
    let block' = { block with kind = Cond cond_block_info' } in
    tl_map := Ident_map.add block.id block' !tl_map
  in

  let cond_both = find_cond_blocks cond_site !tl_map in
  match possible with
  | Some beta ->
      let beta_block =
        if beta
        then Option.value_exn cond_both.else_
        else Option.value_exn cond_both.then_
      in
      make_block_impossible beta_block
  | None -> ()

let _add_callsite site block =
  match block.kind with
  | Fun b ->
      { block with kind = Fun { b with callsites = site :: b.callsites } }
  | _ -> failwith "wrong precondition to call add_callsite"

let add_callsite f_def site tl_map =
  let tl = Ident_map.find f_def tl_map in
  let tl' = _add_callsite site tl in
  Ident_map.add f_def tl' tl_map

(* we cannot use block map to represent the dynamic call graph/stack.
   the point is for one block, we can have a full version and a partial version
   at the same time.
   For this, we may set the original or annotated source code as a (static) map
   and use another data structure for dynamic
*)

(* annotate block from the ddpa cfg.
   for call-site `s = e1 e2`, annotate e1 with the real function def_var
   for cond-site `s = c ? e1 : e2`, replace s with
*)

let annotate e pt : block Ident_map.t =
  let map = ref (block_map_of_expr e)
  (* and visited_pred_map = ref BatMultiPMap.empty *)
  and cfg = Ddpa_analysis.cfg_of e
  (* and id_first = first_var e *)
  and ret_to_fun_def_map = Jayil.Ast_tools.make_ret_to_fun_def_mapping e
  and para_to_fun_def_map = Jayil.Ast_tools.make_para_to_fun_def_mapping e in
  let pt_clause = Ident_map.find pt (Jayil.Ast_tools.clause_mapping e) in
  (* let is_abort_clause =
       match pt_clause with Clause (_, Abort_body) -> true | _ -> false
     in *)
  let acl = Unannotated_clause (lift_clause pt_clause) in

  (* let debug_bomb = ref 20 in *)
  let visited = ref Annotated_clause_set.empty in
  let rec loop acl dangling : unit =
    if Annotated_clause_set.mem acl !visited
    then ()
    else (
      visited := Annotated_clause_set.add acl !visited ;

      let prev_acls = preds_l acl cfg in

      (* debug to prevent infinite loop *)
      (* debug_bomb := !debug_bomb - 1;
         if !debug_bomb = 0
         then failwith "bomb"
         ; *)

      (* process logic *)
      (* if cfg shows only one of then-block and else-block is possible,
         we can change the block accordingly.
         e.g. [prev: [r = c ? ...; r = r1 @- r]]
      *)
      if List.length prev_acls > 1 && has_condition_clause prev_acls
      then
        if List.length prev_acls = 1
        then failwith "cond clause cannot appear along"
        else make_cond_block_possible map prev_acls cfg ;

      (* step logic *)
      let continue = ref true and block_dangling = ref dangling in
      (match acl with
      | Unannotated_clause _ | Start_clause _ | End_clause _ -> ()
      (* into fbody *)
      | Binding_exit_clause
          ( Abs_var _para,
            Abs_var ret_var,
            Abs_clause (Abs_var site_r, Abs_appl_body _) ) ->
          (* para can also be ignored in Fun since para is a property of a Fun block, defined in the source code
            *)
          let f_def = Ident_map.find ret_var ret_to_fun_def_map in
          map := add_id_dst site_r f_def !map ;
          block_dangling := false
      (* out of fbody *)
      | Binding_enter_clause
          (Abs_var para, _, Abs_clause (Abs_var site_r, Abs_appl_body _)) ->
          let f_def = Ident_map.find para para_to_fun_def_map in
          map := add_id_dst site_r f_def !map ;
          map := add_callsite f_def site_r !map ;

          continue := dangling
      (* into cond-body *)
      | Binding_exit_clause
          ( _,
            Abs_var _ret_var,
            Abs_clause (Abs_var _site_r, Abs_conditional_body _) ) ->
          block_dangling := false
      (* out of cond-body *)
      | Nonbinding_enter_clause
          ( Abs_value_bool _cond,
            Abs_clause
              ( Abs_var _site_r,
                Abs_conditional_body (Abs_var _x1, _e_then, _e_else) ) ) ->
          continue := dangling
      | Binding_exit_clause (_, _, _) ->
          failwith "impossible binding exit for non-sites"
      | Binding_enter_clause (_, _, _) ->
          failwith "impossible binding enter for non callsites"
      | Nonbinding_enter_clause (_, _) ->
          failwith "impossible non-binding enter for non condsites") ;
      if !continue
      then List.iter ~f:(fun acl -> loop acl !block_dangling) (preds_l acl cfg))
  in
  let succ_acls = succs_l acl cfg in
  List.iter ~f:(fun acl -> loop acl true) succ_acls ;
  (* loop acl true ; *)
  !map
