open Core
open Graph
open Jhupllib
open Dbmc
open Jayil
open Jayil.Ast
open Jay_instrumentation.Odefa_instrumentation_maps
open Jay.On_to_odefa_maps

module type Error_location = sig
  type t

  val show : t -> string
  val show_brief : t -> string
  val to_yojson : t -> Yojson.Safe.t
end

let replace_linebreaks (str : string) : string =
  String.tr ~target:'\n' ~replacement:' ' str

module Odefa_error_location : Error_location with type t = Ast.clause = struct
  type t = Ast.clause

  let show = Ast_pp.show_clause
  let show_brief = Ast_pp_brief.show_clause
  let to_yojson clause = `String (replace_linebreaks @@ show clause)
end

module Natodefa_error_location :
  Error_location with type t = Jay.On_ast.expr_desc = struct
  type t = Jay.On_ast.expr_desc

  let show = Pp_utils.pp_to_string Jay.On_ast_pp.pp_expr_desc_without_tag
  let show_brief = Pp_utils.pp_to_string Jay.On_ast_pp.pp_expr_desc_without_tag
  let to_yojson expr = `String (replace_linebreaks @@ show expr)
end

module Ton_error_location :
  Error_location with type t = Bluejay.Ton_ast.expr_desc = struct
  type t = Bluejay.Ton_ast.expr_desc

  let show = Pp_utils.pp_to_string Bluejay.Ton_ast_pp.pp_expr_desc_without_tag

  let show_brief =
    Pp_utils.pp_to_string Bluejay.Ton_ast_pp.pp_expr_desc_without_tag

  let to_yojson expr = `String (replace_linebreaks @@ show expr)
end

module type Sato_result = sig
  type t

  val description : string

  val get_errors :
    Sato_state.t ->
    Dbmc.Types.State.t ->
    Dbmc.Interpreter.session ->
    Dbmc.Interpreter.denv ->
    int option list ->
    t

  val show : t -> string
  val show_compact : t -> string
  val count : t -> int
  val to_yojson : t -> Yojson.Safe.t
end

(* **** String showing utilities **** *)
let get_abort_cond_clause_id
    (abort_mapping : (Ident_new.t, abort_value) Hashtbl.t) (ab_id : Ident_new.t)
    : Ident_new.t =
  match Hashtbl.find abort_mapping ab_id with
  | Some ab_val -> ab_val.abort_conditional_ident
  | None -> failwith "Should have a corresponding clause here!"

let get_odefa_errors (sato_state : Sato_state.t)
    (symb_interp_state : Types.State.t) (interp_session : Interpreter.session)
    (final_env : Interpreter.denv) : Ast.clause * Sato_error.Odefa_error.t list
    =
  let abort_var = symb_interp_state.target in
  let ab_mapping = sato_state.abort_mapping in
  let on_to_odefa_maps = sato_state.on_to_odefa_maps in
  let odefa_inst_maps = sato_state.odefa_instrumentation_maps in
  let abort_cond_var = get_abort_cond_clause_id ab_mapping abort_var in
  let (Clause (_, cls) as error_loc) =
    get_pre_inst_equivalent_clause odefa_inst_maps abort_cond_var
  in
  let alias_graph = interp_session.alias_graph in
  let rec find_source_cls cls_mapping xs =
    match xs with
    | [] -> failwith "Should have found a value definition clause!"
    | hd :: tl -> (
        (* let () = print_endline @@ Interpreter.show_ident_with_stack hd in *)
        let found = Hashtbl.find cls_mapping hd in
        match found with
        | Some (cls, _) -> cls
        | None -> find_source_cls cls_mapping tl)
  in
  let mk_match_err expected_type actual_val x x_stk :
      Sato_error.Odefa_error.t list =
    match (expected_type, actual_val) with
    | Bool_type, Value_bool _ | Int_type, Value_int _ -> []
    | _ ->
        let match_aliases_raw = Sato_tools.find_alias alias_graph (x, x_stk) in
        (* let () = print_endline @@ "Printing aliases" in
           let () =
             List.iter ~f:(fun a -> print_endline @@ Interpreter.show_ident_with_stack a)
             match_aliases_raw
           in
           let () = print_endline @@ "---------------" in *)
        let match_val_source =
          find_source_cls interp_session.val_def_map match_aliases_raw
        in
        let match_aliases =
          match_aliases_raw
          (* |> List.map ~f:(fun (x, _) -> x) *)
          |> List.rev
        in
        let actual_type = Sato_tools.get_value_type actual_val in
        let match_error =
          Sato_error.Odefa_error.Error_match
            {
              err_match_aliases = match_aliases;
              err_match_val = match_val_source;
              err_match_expected = expected_type;
              err_match_actual = actual_type;
            }
        in
        [ match_error ]
  in
  let mk_value_error x x_stk =
    (* let () = print_endline "making a value error!" in *)
    let value_aliases_raw = Sato_tools.find_alias alias_graph (x, x_stk) in
    let val_source =
      find_source_cls interp_session.val_def_map value_aliases_raw
    in
    let value_aliases =
      value_aliases_raw
      (* |> List.map ~f:(fun (x, _) -> x) *)
      |> List.rev
    in
    let value_error =
      Sato_error.Odefa_error.Error_value
        { err_value_aliases = value_aliases; err_value_val = val_source }
    in
    [ value_error ]
  in
  let error_list =
    match cls with
    (* If the point of error is a binary operation, we know that one of
       the two operands must have taken the wrong type.
    *)
    | Binary_operation_body (Var (x1, _), _, Var (x2, _)) ->
        let expected_type = Sato_tools.get_expected_type_from_cls cls in
        let (x1_val, x1_stk), (x2_val, x2_stk) =
          let dv1, stk1 = Ident_map.find x1 final_env in
          let dv2, stk2 = Ident_map.find x2 final_env in
          let v1, v2 =
            (Interpreter.value_of_dvalue dv1, Interpreter.value_of_dvalue dv2)
          in
          ((v1, stk1), (v2, stk2))
        in
        (* let () = print_endline @@ "This is the final error idents" in
           let () = print_endline @@ Interpreter.show_ident_with_stack (x1, x1_stk) in
           let () = print_endline @@ Interpreter.show_ident_with_stack (x2, x2_stk) in *)
        let left_error = mk_match_err expected_type x1_val x1 x1_stk in
        let right_error = mk_match_err expected_type x2_val x2 x2_stk in
        let errors = List.append left_error right_error in
        errors
    (* The following operations are all potential candidates where type errors
        can occur. *)
    | Not_body (Var (x, _))
    | Appl_body (Var (x, _), _)
    | Projection_body (Var (x, _), _)
    | Conditional_body (Var (x, _), _, _) ->
        (* let () = print_endline @@ show_ident x in *)
        (* let () = print_endline @@ Ast_pp.show_clause_body cls in *)
        let expected_type = Sato_tools.get_expected_type_from_cls cls in
        let x_val, x_stk =
          let dv, stk = Ident_map.find x final_env in
          let v = Interpreter.value_of_dvalue dv in
          (v, stk)
        in
        let error = mk_match_err expected_type x_val x x_stk in
        (* If the error list is empty, that means it's an error where
           the condition variable leads to an abort in one of the
           branches. *)
        if List.is_empty error
        then
          let val_error = mk_value_error x x_stk in
          val_error
        else error
    | _ -> []
  in
  (error_loc, error_list)

type odefa_error_record = {
  err_errors : Sato_error.Odefa_error.t list;
  err_input_seq : int option list;
  err_location : Odefa_error_location.t;
}
[@@deriving to_yojson]

(* **** Odefa Type Errors **** *)

module Odefa_type_errors : Sato_result with type t = odefa_error_record = struct
  type t = odefa_error_record

  let description = "error"

  let get_errors (sato_state : Sato_state.t)
      (symb_interp_state : Dbmc.Types.State.t)
      (interp_session : Dbmc.Interpreter.session)
      (final_env : Dbmc.Interpreter.denv) (inputs : int option list) : t =
    let error_loc, odefa_errors =
      get_odefa_errors sato_state symb_interp_state interp_session final_env
    in
    let odefa_inst_maps = sato_state.odefa_instrumentation_maps in
    let rm_inst_fn =
      Sato_error.odefa_error_remove_instrument_vars odefa_inst_maps
    in
    {
      err_input_seq = inputs;
      err_location = error_loc;
      err_errors = List.map ~f:rm_inst_fn odefa_errors;
    }

  let show : t -> string =
   fun error ->
    "** Odefa Type Errors **\n"
    ^ Printf.sprintf "- Input sequence  : %s\n"
        (Dbmc.Std.string_of_inputs error.err_input_seq)
    ^ Printf.sprintf "- Found at clause : %s\n"
        (Odefa_error_location.show error.err_location)
    (* (Printf.sprintf "- Found in steps  : %s\n" (string_of_int error.err_steps)) ^ *)
    ^ "--------------------\n"
    ^ String.concat ~sep:"\n--------------------\n"
    @@ List.map ~f:Sato_error.Odefa_error.show error.err_errors

  let show_compact : t -> string =
   fun error ->
    "- err at: " ^ Odefa_error_location.show_brief error.err_location

  let count : t -> int = fun err -> List.length err.err_errors

  let to_yojson : t -> Yojson.Safe.t =
   fun err -> odefa_error_record_to_yojson err
end

(* **** Natodefa Type Errors **** *)

type natodefa_error_record = {
  err_errors : Sato_error.On_error.t list;
  err_input_seq : int option list;
  err_location : Natodefa_error_location.t;
}
[@@deriving to_yojson]

module Natodefa_type_errors : Sato_result with type t = natodefa_error_record =
struct
  type t = natodefa_error_record

  let description = "natodefa type error"

  let get_errors (sato_state : Sato_state.t)
      (symb_interp_state : Dbmc.Types.State.t)
      (interp_session : Dbmc.Interpreter.session)
      (final_env : Dbmc.Interpreter.denv) (inputs : int option list) =
    let open Jay in
    let (Clause (Var (err_id, _), _) as error_loc), odefa_errors =
      get_odefa_errors sato_state symb_interp_state interp_session final_env
    in
    let odefa_inst_maps = sato_state.odefa_instrumentation_maps in
    let on_to_odefa_maps = Option.value_exn sato_state.on_to_odefa_maps in
    let on_err_loc_core =
      err_id
      |> On_to_odefa_maps.get_natodefa_equivalent_expr_exn on_to_odefa_maps
    in
    let on_err_list =
      let mapper =
        Sato_error.odefa_to_natodefa_error odefa_inst_maps on_to_odefa_maps
          interp_session final_env
      in
      List.map ~f:mapper odefa_errors
    in
    {
      err_input_seq = inputs;
      err_location = on_err_loc_core;
      err_errors = List.concat on_err_list;
    }

  let show : t -> string =
   fun error ->
    "** NatOdefa Type Errors **\n"
    ^ Printf.sprintf "- Input sequence  : %s\n"
        (Dbmc.Std.string_of_inputs error.err_input_seq)
    ^ Printf.sprintf "- Found at clause : %s\n"
        (Natodefa_error_location.show error.err_location)
    ^ "--------------------\n"
    ^ String.concat ~sep:"\n--------------------\n"
    @@ List.map ~f:Sato_error.On_error.show error.err_errors

  let show_compact : t -> string =
   fun error ->
    "- err at: " ^ Natodefa_error_location.show_brief error.err_location

  let count : t -> int = fun err -> List.length err.err_errors

  let to_yojson : t -> Yojson.Safe.t =
   fun err -> natodefa_error_record_to_yojson err
end

(* **** Typed Natodefa Type Errors **** *)

type ton_error_record = {
  err_errors : Sato_error.Ton_error.t list;
  err_input_seq : int option list;
  err_location : Ton_error_location.t;
}
[@@deriving to_yojson]

module Ton_type_errors : Sato_result with type t = ton_error_record = struct
  type t = ton_error_record

  let description = "typed natodefa type error"

  let get_errors (sato_state : Sato_state.t)
      (symb_interp_state : Dbmc.Types.State.t)
      (interp_session : Dbmc.Interpreter.session)
      (final_env : Dbmc.Interpreter.denv) (inputs : int option list) =
    let open Jay in
    let open Bluejay in
    let (Clause (Var (err_id, _), _) as error_loc), odefa_errors =
      get_odefa_errors sato_state symb_interp_state interp_session final_env
    in
    let odefa_inst_maps = sato_state.odefa_instrumentation_maps in
    let on_to_odefa_maps = Option.value_exn sato_state.on_to_odefa_maps in
    let ton_on_maps = Option.value_exn sato_state.ton_on_maps in
    let on_err_loc_syn =
      err_id
      |> On_to_odefa_maps.get_natodefa_equivalent_expr_exn on_to_odefa_maps
      |> Ton_ast_internal.from_natodefa_expr_desc
      |> Ton_to_on_maps.sem_natodefa_from_core_natodefa ton_on_maps
      |> Ton_to_on_maps.syn_natodefa_from_sem_natodefa ton_on_maps
      |> Ton_ast_internal.from_internal_expr_desc
    in
    let is_type_error =
      match on_err_loc_syn.body with
      | LetWithType _ | LetFunWithType _ | LetRecFunWithType _ -> true
      | _ -> false
    in
    let ton_err_list =
      let mapper =
        if is_type_error
        then
          Sato_error.odefa_to_ton_error odefa_inst_maps on_to_odefa_maps
            ton_on_maps interp_session on_err_loc_syn
        else
          Sato_error.odefa_to_ton_error_simple odefa_inst_maps on_to_odefa_maps
            ton_on_maps interp_session final_env
      in
      List.map ~f:mapper odefa_errors
    in
    {
      err_input_seq = inputs;
      err_location = on_err_loc_syn;
      err_errors = List.concat ton_err_list;
    }

  let show : t -> string =
   fun error ->
    "** Typed Natodefa Type Errors **\n"
    ^ Printf.sprintf "- Input sequence  : %s\n"
        (Dbmc.Std.string_of_inputs error.err_input_seq)
    ^ Printf.sprintf "- Found at clause : %s\n"
        (Ton_error_location.show error.err_location)
    ^ "--------------------\n"
    ^ String.concat ~sep:"\n--------------------\n"
    @@ List.map ~f:Sato_error.Ton_error.show error.err_errors

  let show_compact : t -> string =
   fun error -> "- err at: " ^ Ton_error_location.show_brief error.err_location

  let count : t -> int = fun err -> List.length err.err_errors
  let to_yojson : t -> Yojson.Safe.t = fun err -> ton_error_record_to_yojson err
end

(* **** Unifying Type Errors **** *)
type reported_error =
  | Ton_error of Ton_type_errors.t
  | Natodefa_error of Natodefa_type_errors.t
  | Odefa_error of Odefa_type_errors.t

let show_reported_error err =
  match err with
  | Ton_error ton_err -> Ton_type_errors.show ton_err
  | Natodefa_error nat_err -> Natodefa_type_errors.show nat_err
  | Odefa_error odefa_err -> Odefa_type_errors.show odefa_err