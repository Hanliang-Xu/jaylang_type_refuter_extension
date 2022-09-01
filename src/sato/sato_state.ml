open Core
open Jayil.Ast

type mode = Sato_args.mode = Odefa | Natodefa | Typed_natodefa
[@@deriving show]

type t = {
  (* basic *)
  sato_mode : mode;
  program : expr;
  (* book-keeping *)
  abort_mapping : (Ident_new.t, abort_value) Hashtbl.t;
  target_vars : Ident_new.t list;
  odefa_instrumentation_maps : Jay_instrumentation.Odefa_instrumentation_maps.t;
  on_to_odefa_maps : Odefa_natural.On_to_odefa_maps.t option;
  ton_on_maps : Typed_odefa_natural.Ton_to_on_maps.t option;
}

(* Enumerate all aborts in a program *)
let rec enum_all_aborts_in_expr expr : (ident * abort_value) list =
  let (Expr clauses) = expr in
  List.concat @@ List.map ~f:enum_all_aborts_in_clause clauses

and enum_all_aborts_in_clause clause : (ident * abort_value) list =
  let (Clause (Var (cls_id, _), body)) = clause in
  match body with
  | Conditional_body (Var (pred_id, _), e1, e2) ->
      let enum_ret_abort e branch =
        let (Expr c_list) = e in
        match List.last c_list with
        | None -> []
        | Some cls -> (
            match cls with
            | Clause (Var (abort_id, _), Abort_body) ->
                let abort_val =
                  {
                    abort_conditional_ident = cls_id;
                    abort_predicate_ident = pred_id;
                    abort_conditional_branch = branch;
                  }
                in
                [ (abort_id, abort_val) ]
            | _ -> [])
      in
      []
      |> List.append (enum_all_aborts_in_expr e1)
      |> List.append (enum_ret_abort e1 true)
      |> List.append (enum_all_aborts_in_expr e2)
      |> List.append (enum_ret_abort e2 false)
  | Value_body v -> enum_all_aborts_in_value v
  | Abort_body (* Aborts are enumerated in conditionals *)
  | Assume_body _ | Assert_body _ | Var_body _ | Input_body
  | Appl_body (_, _)
  | Binary_operation_body (_, _, _)
  | Not_body _
  | Match_body (_, _)
  | Projection_body (_, _) ->
      []

and enum_all_aborts_in_value value : (ident * abort_value) list =
  match value with
  | Value_function (Function_value (_, e)) -> enum_all_aborts_in_expr e
  | Value_int _ | Value_bool _ | Value_record _ -> []

let get_target_vars (abort_mapping : (Ident_new.t, abort_value) Hashtbl.t) :
    ident list =
  abort_mapping |> Hashtbl.keys

let initialize_state_with_expr (sato_mode : mode) (e : expr)
    (odefa_inst_maps : Jay_instrumentation.Odefa_instrumentation_maps.t)
    (on_to_odefa_maps_opt : Odefa_natural.On_to_odefa_maps.t option)
    (ton_to_on_maps_opt : Typed_odefa_natural.Ton_to_on_maps.t option) : t =
  let abort_lst = enum_all_aborts_in_expr e in
  let ab_mapping = Hashtbl.of_alist_exn (module Ident_new) abort_lst in
  let targets = get_target_vars ab_mapping in
  {
    sato_mode;
    program = e;
    abort_mapping = ab_mapping;
    target_vars = targets;
    odefa_instrumentation_maps = odefa_inst_maps;
    on_to_odefa_maps = on_to_odefa_maps_opt;
    ton_on_maps = ton_to_on_maps_opt;
  }
