open Batteries
(* open Jhupllib *)
open Odefa_ast
open Ast
(* open Ast_pp *)
open Odefa_ddpa
open Ddpa_abstract_ast
open Ddpa_graph
(* open Ddpa_utils *)
(* open Interpreter_types;; *)
(* open Logger_utils *)

open Ast_helper

let log_acl acl prevs = 
  print_endline @@ Printf.sprintf "%s \t\t[prev: %s]"
    (Jhupllib.Pp_utils.pp_to_string
       pp_brief_annotated_clause acl)
    (Jhupllib.Pp_utils.pp_to_string
       (Jhupllib.Pp_utils.pp_list pp_brief_annotated_clause) prevs)

let log_id id = 
  print_endline @@ Printf.sprintf "%s"
    (Jhupllib.Pp_utils.pp_to_string pp_ident id)

module Tracelet = struct

  (* TODO: we might get rid of map at all, by using tree (zipper) *)
  let name_main = "0_main"

  let id_main = Ident name_main

  (* duplicate for simplicity *)
  type trace_clause = 
    | App | Fun | Cond | Direct of clause

  type id_with_dst = ident * ident list

  type block = {
    clauses : (ident * trace_clause) list;
    app_ids : id_with_dst list;
    cond_ids : id_with_dst list;
    (* first_v : id of the first clause *)
    (* ret: id of the last clause *)
  }

  let empty_block = {
    clauses = []; app_ids = []; cond_ids = []
  }

  type fun_block = {
    para: ident;
    block: block;
  }

  type cond_source_block = { 
    cond : ident;
    then_block : block;
    else_block : block;
  }

  type cond_running_block = {
    cond : ident;
    choice : bool;
    block : block;
    other_block : block;
  }

  type block_node = 
    | Main of block
    | Fun of fun_block
    | CondBoth of cond_source_block
    | CondChosen of cond_running_block

  type source_tracelet = {
    point : ident;
    outer_point : ident;
    source_block : block_node;
  }

  type t = source_tracelet

  type block_cat = 
    | Whole
    | Partial of ident

  let get_block tl =
    match tl.source_block with
    | Main b -> b
    | Fun b -> b.block
    | CondBoth c -> 
      {
        clauses = c.then_block.clauses @ c.else_block.clauses;
        app_ids = c.then_block.app_ids @ c.else_block.app_ids;
        cond_ids = c.then_block.cond_ids @ c.else_block.cond_ids
      }
    | CondChosen c -> c.block

  let update_block f tl =
    let source_block = 
      match tl.source_block with
      | Main b -> Main (f b)
      | Fun b -> Fun 
                   {b with
                    block = f b.block
                   }
      | CondBoth c -> CondBoth 
                        {c with 
                         then_block = f c.then_block;
                         else_block = f c.else_block
                        }
      | CondChosen c -> CondChosen 
                          {c with
                           block = f c.block;
                           other_block = f c.other_block
                          }
    in
    {tl with source_block}


  let running_cond choice (cb : cond_source_block) : cond_running_block =
    { cond = cb.cond;
      choice;
      block = if choice then cb.then_block else cb.else_block;
      other_block = if choice then cb.else_block else cb.then_block;
    }

  let cids_of tl =
    tl
    |> get_block
    |> fun block -> List.map (fun (Ident id, _) -> id) block.clauses    

  let direct_cids_of tl =
    tl
    |> get_block
    |> fun block -> List.filter_map (function
        | (Ident id, Direct _) -> Some id
        | _ -> None) block.clauses

  let app_ids_of tl =
    tl
    |> get_block
    |> fun block -> List.map (fun (Ident id, _) -> id) block.app_ids   

  let cond_ids_of tl =
    tl
    |> get_block
    |> fun block -> List.map (fun (Ident id, _) -> id) block.cond_ids   

  let debug_def_ids_of tl =
    tl
    |> get_block
    |> fun block -> List.map (fun (Ident id, dsts) -> 
        let dst_names = List.map (fun (Ident name) -> name) dsts in
        id, dst_names)
      (block.app_ids @ block.cond_ids)

  let split_clauses (Expr clauses) : (ident * trace_clause) list * id_with_dst list * id_with_dst list =
    List.fold_left (fun (cs, app_ids, cond_ids) (Clause(Var (cid, _), b) as c) ->
        match b with
        | Appl_body (_, _)
          -> (cs @ [cid, App], app_ids @ [cid, []], cond_ids)
        | Conditional_body (Var (x, _), _, _)
          -> (cs @ [cid, Cond], app_ids, cond_ids @ [cid, []])
        | Value_body (Value_function _)
          -> (cs @ [cid, Fun], app_ids, cond_ids)
        | _
          -> (cs @ [cid, Direct c], app_ids, cond_ids)

      ) ([], [], []) clauses

  let block_of_expr e =
    let clauses, app_ids, cond_ids = split_clauses e in
    { clauses; app_ids; cond_ids }

  let tracelet_map_of_expr e : t Ident_map.t =
    let map = ref Ident_map.empty in

    let main_tracelet = 
      let block = block_of_expr e in
      let source_block = Main block in
      { point = id_main; outer_point = id_main; source_block } in
    map := Ident_map.add id_main main_tracelet !map
    ;

    let rec loop outer_point e =
      let Expr clauses = e in
      let handle_clause = function
        | Clause (Var (cid, _), Value_body (Value_function (Function_value (Var (para, _), fbody)))) ->
          let block = block_of_expr fbody in
          let source_block = Fun { para; block } in
          let tracelet = 
            { point = cid ; outer_point; source_block } in
          map := Ident_map.add cid tracelet !map;
          loop cid fbody
        | Clause (Var (cid, _), Conditional_body (Var(cond, _), e1, e2)) ->
          let then_block = block_of_expr e1
          and else_block = block_of_expr e2 in
          let source_block = 
            CondBoth {cond; then_block; else_block} in
          let tracelet = 
            { point = cid ; outer_point; source_block } in
          map := Ident_map.add cid tracelet !map;
          loop cid e1;
          loop cid e2     
        | _ -> ()
      in
      List.iter handle_clause clauses
    in

    loop id_main e;
    !map

  let cut_before x tl =
    let cut_block block : block = 
      let clauses, app_ids, cond_ids =
        List.fold_while 
          (fun _acc (cid, _c) -> cid <> x)
          (fun (cs, app_ids, cond_ids) (cid, tc as cc) ->
             (* TODO: bad design *)
             match tc with
             | App ->
               let dst = List.assoc cid block.app_ids in
               (cs @ [cc], app_ids @ [cid, dst], cond_ids)
             | Cond ->
               let dst = List.assoc cid block.cond_ids in
               (cs @ [cc], app_ids, cond_ids @ [cid, dst])
             | Fun ->
               (cs @ [cc], app_ids, cond_ids)
             | Direct cd ->
               (cs @ [cc], app_ids, cond_ids)
          )
          ([], [], [])
          block.clauses
        |> fst
      in
      { clauses; app_ids; cond_ids }
    in
    let source_block = 
      match tl.source_block with
      | Main b -> Main (cut_block b)
      | Fun b -> Fun { b with block = cut_block b.block }
      | CondBoth cond ->
        (* TODO : 
           Noting: cutting can only occur in one block of a cond, therefore
           it's a hidden change from CondBoth to CondChosen
        *)
        let choice = List.mem_assoc x cond.then_block.clauses in
        let cond' = running_cond choice cond in
        CondChosen { cond' with block = cut_block cond'.block }
      | CondChosen cond -> 
        CondChosen { cond with block = cut_block cond.block }
    in
    { tl with source_block }

  let find_by_id x tl_map =
    tl_map
    |> Ident_map.values
    |> Enum.find (fun tl -> List.mem_assoc x @@ (get_block tl).clauses )

  let cut_before_id x tl_map =
    find_by_id x tl_map
    |> cut_before x

  let update_id_dst id dst0 tl =
    let add_dst = function
      | Some dst -> 
        Some (if List.mem dst0 dst then dst else dst0::dst)
      | None -> None
    in
    update_block 
      (fun block -> 
         let app_ids = List.modify_opt id add_dst block.app_ids
         and cond_ids = List.modify_opt id add_dst block.cond_ids
         in
         { block with app_ids; cond_ids }
      )
      tl

  let add_id_dst site_x def_x tl_map =
    (* log_id site_x; *)
    (* log_id def_x; *)
    let tl = find_by_id site_x tl_map in
    (* log_id tl.point; *)
    let tl' = update_id_dst site_x def_x tl in
    Ident_map.add tl.point tl' tl_map

end

(* open Tracelet *)

module Tunnel = struct
  (* let clauses = Ast_tools.flatten e in
     let (Clause (Var (_, id0), _)) = List.hd clauses in
     List.fold_while
     (fun (flag, prev) _ -> flag)
     (fun (flag, prev) c -> match c with
       | Clause (Var (_, id), Value_body(Value_function _))
       | Clause (Var (_, id), Conditional_body(_, _, _)) ->
         true, prev
       | _ -> 
         true, prev
     )
     (false, id0)
     clauses *)
  type callsite_tunnel = ident Ident_map.t

  exception Invalid_query of string

  (* ddpa adapter *)
  let cfg_of e =
    let open Odefa_ddpa in
    let conf : (module Ddpa_context_stack.Context_stack) = 
      (module Ddpa_single_element_stack.Stack) in
    let module Stack = (val conf) in
    let module Analysis = Ddpa_analysis.Make(Stack) in
    e
    |> Analysis.create_initial_analysis
    |> Analysis.perform_full_closure
    |> Analysis.cfg_of_analysis

  (* let map = ref BatMultiPMap.empty
     map := BatMultiPMap.add id_start id_start !map;
     !map
  *)

  (* annotate tracelet from the ddpa cfg.
     for call-site `s = e1 e2`, annotate e1 with the real function def_var
     for cond-site `s = c ? e1 : e2`, replace s with 
  *)
  let annotate e pt =
    print_newline ();
    let map = ref (Tracelet.tracelet_map_of_expr e)
    (* and visited_pred_map = ref BatMultiPMap.empty *)
    and cfg = cfg_of e
    (* and id_first = first_var e *)
    and ret_to_fun_def_map =
      make_ret_to_fun_def_mapping e 
    and para_to_fun_def_map = 
      make_para_to_fun_def_mapping e
    and acl =
      try
        Unannotated_clause(
          lift_clause @@ Ident_map.find pt (clause_mapping e))
      with
      | Not_found ->
        raise @@ Invalid_query(
          Printf.sprintf "Variable %s is not defined" (show_ident pt))
    in
    (* let debug_bomb = ref 20 in *)
    let rec loop acl dangling : unit = 
      let prev_acls = List.of_enum @@ preds acl cfg in
      log_acl acl prev_acls;

      (* process logic *)


      (* step logic *)
      let continue = ref true
      and block_dangling = ref dangling in
      begin
        match acl with
        | Unannotated_clause _
        | Start_clause _ | End_clause _ ->
          ()
        (* into fbody *)
        | Binding_exit_clause (Abs_var _para, Abs_var ret_var, Abs_clause(Abs_var site_r, Abs_appl_body _)) -> 
          (* para can also be ignored in Fun since para is a property of a Fun block, defined in the source code
          *)
          let f_def = Ident_map.find ret_var ret_to_fun_def_map in
          map := Tracelet.add_id_dst site_r f_def !map;
          block_dangling := false
        (* out of fbody *)
        | Binding_enter_clause (Abs_var para, _, Abs_clause(Abs_var site_r, Abs_appl_body _)) ->
          let f_def = Ident_map.find para para_to_fun_def_map in
          map := Tracelet.add_id_dst site_r f_def !map;
          continue := dangling
        (* into cond-body *)
        | Binding_exit_clause (_, Abs_var ret_var, Abs_clause(Abs_var site_r, Abs_conditional_body _)) -> 
          block_dangling := false
        (* out of cond-body *)
        | Nonbinding_enter_clause (Abs_value_bool cond, 
                                   Abs_clause(Abs_var site_r, Abs_conditional_body(Abs_var x1, _e_then, _e_else))) ->
          continue := dangling
        | Binding_exit_clause (_, _, _) ->
          failwith "impossible binding exit for non-sites"
        | Binding_enter_clause (_, _, _) ->
          failwith "impossible binding enter for non callsites"
        | Nonbinding_enter_clause (_, _) ->
          failwith "impossible non-binding enter for non condsites"
      end;
      if !continue
      then
        Enum.iter (fun acl -> loop acl !block_dangling) (preds acl cfg)
      else
        ()
    in
    loop acl true;
    !map
end


(* 
annotated_clause

initial acl

Unannotated_clause(
  lift_clause @@ Ident_map.find program_point env.le_clause_mapping)


usage of acl

let%bind acl1 = pick @@ preds acl0 env.le_cfg in

acl |> x |> pattern match
 *)

(* ddpa workflow

   Make(Context_stack) -> Analysis_sig

   Context_stack =
   | n_elem | non_repeating | single_elem | two_elem | unit_stack


   create_initial_analysis : expr -> ddpa_alys
    => Abs_expr(cls) = lift_expr e

   perform_closure_steps : ddpa_alys -> ddpa_alys
    => ...

   perform_full_closure : ddpa_alys -> ddpa_alys
    recursively call perform_closure_steps until `is_fully_closed`



   cfg_of_analysis : ddpa_alys -> ddpa_graph

   type ddpa_analysis = {
    { ddpa_graph : ddpa_graph
    ; ddpa_graph_fully_closed : bool
    ; pds_reachability : Ddpa_pds_reachability.analysis
    ; ddpa_active_nodes : Annotated_clause_set.t
    ; ddpa_active_non_immediate_nodes : Annotated_clause_set.t
    ; ddpa_logging_data : ddpa_analysis_logging_data option
    }
   }

*)

(* outside
   sym_interpreter.ml:

   start : ddpa_graph -> expr -> ident --> evaluation
      => prepare_environment : expr -> ddpa_graph --> lookup_environment

    lookup: lookup_environment -> lookup_stack -> annotated_clause -> relstack -> symbol M.monad

   lookup :
    let%bind acl1 = pick @@ preds acl0 env.le_cfg in

   generator.ml:

   create : policy -> conf -> expr -> Id --> test_generator
      => cfg = e 
              |> create_initial_analysis
              |> perform_full_closure
              |> cfg_of_analysis
      => start
*)

