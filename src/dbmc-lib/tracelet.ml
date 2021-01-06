open Core
open Odefa_ast.Ast

open Odefa_ddpa
open Ddpa_abstract_ast
open Ddpa_graph
open Ddpa_helper

let name_main = "0_main"
let id_main = Ident name_main

type clause_cat = 
  | Direct
  | Fun 
  | App of ident list
  | Cond of ident list
[@@deriving show {with_path = false}]

type tl_clause = {
  id : ident;
  cat : clause_cat;
  clause : clause [@opaque];
}
[@@deriving show {with_path = false}]

type clause_list = tl_clause list
[@@deriving show {with_path = false}]

type main_block = {
  point : ident;

  clauses: clause_list;
} [@@deriving show {with_path = false}]


type fun_block = {
  point : ident;
  outer_point : ident;

  para: ident;
  clauses: clause_list;
  callsites: ident list;
} [@@deriving show {with_path = false}]

type cond_block = { 
  point : ident;
  outer_point : ident;

  cond : ident;
  possible : bool option;
  choice : bool option;
  then_ : clause_list;
  else_ : clause_list;
} [@@deriving show {with_path = false}]

type block = 
  | Main of main_block
  | Fun of fun_block
  | Cond of cond_block
[@@deriving show {with_path = false}]

type t = block
[@@deriving show {with_path = false}]

let get_clauses block = 
  match block with
  | Main mb -> mb.clauses
  | Fun fb -> fb.clauses
  | Cond cb ->
    let choice = BatOption.get cb.choice in
    if choice then
      cb.then_
    else
      cb.else_

let id_of_block = function
  | Main b -> b.point
  | Fun fb -> fb.point
  | Cond cb -> cb.point

let outer_id_of_block = function
  | Main _b -> failwith "no outer_point for main block"
  | Fun fb -> fb.outer_point
  | Cond cb -> cb.outer_point

let ret_of block =
  let clauses = get_clauses block in
  (List.last_exn clauses).id

let update_clauses f block =
  match block with
  | Main b -> 
    let clauses = f b.clauses in 
    Main { b with clauses }
  | Fun b -> 
    let clauses = f b.clauses in 
    Fun { b with clauses }
  | Cond c -> 
    let then_ = f c.then_ in
    let else_ = f c.else_ in 
    Cond {c with then_ ; else_ }

let find_by_id x block_map =
  block_map
  (* |> Map.data *)
  |> Ident_map.values
  |> bat_list_of_enum
  |> List.find_map ~f:(fun tl -> match tl with
      | Main b -> 
        if List.exists ~f:(fun tc -> Ident.equal tc.id x) b.clauses then
          Some tl
        else
          None
      | Fun b -> 
        if List.exists ~f:(fun tc -> Ident.equal tc.id x) b.clauses then
          Some tl
        else
          None
      | Cond c -> 
        if List.exists ~f:(fun tc -> Ident.equal tc.id x) c.then_ then
          Some (Cond {c with choice = Some true})
        else if List.exists ~f:(fun tc -> Ident.equal tc.id x) c.else_ then
          Some (Cond {c with choice = Some false})
        else
          None
    )
  |> Option.value_exn 

let clause_of_x block x =
  List.find ~f:(fun tc -> Ident.equal tc.id x) (get_clauses block)

let clause_of_x_exn block x =
  List.find_exn ~f:(fun tc -> Ident.equal tc.id x) (get_clauses block)

let update_id_dst id dst0 block =
  let add_dsts dst0 dsts =
    if List.mem dsts dst0 ~equal:Ident.equal
    then dsts
    else (dst0 :: dsts)
  in
  let add_dst_in_clause tc = 
    if Ident.equal tc.id id
    then { tc with cat = match tc.cat with
        | App dsts -> App (add_dsts dst0 dsts)
        | Cond dsts -> Cond (add_dsts dst0 dsts)
        | other -> other
      }
    else tc
  in
  update_clauses (List.map ~f:add_dst_in_clause) block

let add_id_dst site_x def_x tl_map =
  let tl = find_by_id site_x tl_map in
  let tl' = update_id_dst site_x def_x tl in
  (* Map.add ~key:(id_of_block tl) ~data:tl' tl_map *)
  Ident_map.add (id_of_block tl) tl' tl_map

let choose_cond_block acls cfg tl_map =
  let cond_site, choice =
    match acls with
    | Unannotated_clause(Abs_clause(Abs_var cond_site, Abs_conditional_body _)) 
      :: wire_cl
      :: [] -> 
      cond_site, find_cond_top wire_cl cfg
    | _ -> failwith "wrong precondition to call"
  in
  let tl = Ident_map.find cond_site tl_map in
  let tracelet' = match tl with 
    | Cond c -> (
        let p' = match c.possible with
          | Some p when Bool.equal p choice -> Some p
          | Some _p (* p <> choice *)-> None
          | None -> Some choice
        in          
        Cond { c with possible = p' }
      )
    | _ -> failwith "it should called just once on CondBoth"
  in
  Ident_map.add cond_site tracelet' tl_map

let _add_callsite site tl =
  match tl with
  | Fun b -> Fun { b with callsites = (site :: b.callsites) }
  | _ -> failwith "wrong precondition to call add_callsite"

(* let add_callsite f_def site tl_map =
   let tl = Map.find_exn tl_map f_def in
   let tl' = _add_callsite site tl in
   Map.add_exn ~key:f_def ~data:tl' tl_map *)

let add_callsite f_def site tl_map =
  let tl = Ident_map.find f_def tl_map in
  let tl' = _add_callsite site tl in
  Ident_map.add f_def tl' tl_map

let clauses_of_expr e =
  let (Expr clauses) = e in 
  List.fold_left clauses ~init:[] ~f:(fun cs (Clause(Var (cid, _), b) as c) ->
      let c' = match b with
        | Appl_body (_, _)
          -> { id = cid; cat = App []; clause = c }
        | Conditional_body (Var (_, _), _, _)
          -> { id = cid; cat = Cond []; clause = c }
        | Value_body (Value_function _)
          -> { id = cid; cat = Fun; clause = c }
        | _
          -> { id = cid; cat = Direct; clause = c }
      in
      cs @ [c']
    )

let tracelet_map_of_expr e : t Ident_map.t =
  let map = ref Ident_map.empty in

  let main_tracelet = 
    let clauses = clauses_of_expr e in
    Main { point = id_main; clauses } in
  map := Ident_map.add id_main main_tracelet !map
  ;

  let rec loop outer_point e =
    let Expr clauses = e in
    let handle_clause = function
      | Clause (Var (cid, _), Value_body (Value_function (Function_value (Var (para, _), fbody)))) ->
        let clauses = clauses_of_expr fbody in
        let tracelet = 
          Fun { point = cid ; outer_point; para; callsites = []; clauses } in
        map := Ident_map.add cid tracelet !map;
        loop cid fbody
      | Clause (Var (cid, _), Conditional_body (Var(cond, _), e1, e2)) ->
        let then_ = clauses_of_expr e1
        and else_ = clauses_of_expr e2 
        and possible = None in
        let tracelet = 
          Cond { point = cid ; outer_point; cond; possible; then_; else_; choice = None } in
        map := Ident_map.add cid tracelet !map;
        loop cid e1;
        loop cid e2     
      | _ -> ()
    in
    List.iter clauses ~f:handle_clause
  in

  loop id_main e;
  !map

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

(* we cannot use tracelet map to represent the dynamic call graph/stack.
   the point is for one block, we can have a full version and a partial version
   at the same time.
   For this, we may set the original or annotated source code as a (static) map
   and use another data structure for dynamic
*)

(* annotate tracelet from the ddpa cfg.
   for call-site `s = e1 e2`, annotate e1 with the real function def_var
   for cond-site `s = c ? e1 : e2`, replace s with 
*)

let annotate e pt : block Ident_map.t =
  let map = ref (tracelet_map_of_expr e)
  (* and visited_pred_map = ref BatMultiPMap.empty *)
  and cfg = cfg_of e
  (* and id_first = first_var e *)
  and ret_to_fun_def_map =
    make_ret_to_fun_def_mapping e 
  and para_to_fun_def_map = 
    make_para_to_fun_def_mapping e
  and acl =
    Unannotated_clause(
      lift_clause @@ Ident_map.find pt (clause_mapping e))
    (* try
       Unannotated_clause(
        lift_clause @@ Ident_map.find pt (clause_mapping e))
       with
       | Not_found ->
       raise @@ Interpreter.Invalid_query(
        Printf.sprintf "Variable %s is not defined" (show_ident pt)) *)
  in

  (* let debug_bomb = ref 20 in *)
  let visited = ref Annotated_clause_set.empty in
  (* map := BatMultiPMap.add id_start id_start !map;
     !map *)
  let rec loop acl dangling : unit = 
    if Annotated_clause_set.mem acl !visited
    then ()
    else
      begin
        visited := Annotated_clause_set.add acl !visited;

        let prev_acls = preds_l acl cfg in
        (* debug to prevent infinite loop *)
        (* debug_bomb := !debug_bomb - 1;
           if !debug_bomb = 0
           then failwith "bomb"
           else ()
           ; *)

        (* process logic *)
        (* if cfg shows only one of then-block and else-block is possible,
           we can change the tracelet accordingly.
           e.g. [prev: [r = c ? ...; r = r1 @- r]]
        *)
        if List.length prev_acls = 2 && has_condition_clause prev_acls
        then map := choose_cond_block prev_acls cfg !map
        else ()
        ;

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
            map := add_id_dst site_r f_def !map;
            block_dangling := false
          (* out of fbody *)
          | Binding_enter_clause (Abs_var para, _, Abs_clause(Abs_var site_r, Abs_appl_body _)) ->
            let f_def = Ident_map.find para para_to_fun_def_map in
            map := add_id_dst site_r f_def !map;
            map := add_callsite f_def site_r !map;

            continue := dangling
          (* into cond-body *)
          | Binding_exit_clause (_, Abs_var _ret_var, Abs_clause(Abs_var _site_r, Abs_conditional_body _)) -> 
            block_dangling := false
          (* out of cond-body *)
          | Nonbinding_enter_clause (Abs_value_bool _cond, 
                                     Abs_clause(Abs_var _site_r, Abs_conditional_body(Abs_var _x1, _e_then, _e_else))) ->
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
          List.iter ~f:(fun acl -> loop acl !block_dangling) (preds_l acl cfg)
        else
          ()

      end
  in
  loop acl true;
  !map