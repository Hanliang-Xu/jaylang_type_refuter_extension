open Batteries;;
open Jhupllib;;

open Odefa_ast;;
open On_ast;;

(* **** Natodefa module signatures **** *)

module type Error_ident = sig
  type t;;
  val equal : t -> t -> bool;;
  val pp : t Pp_utils.pretty_printer;;
  val show : t -> string;;
  val to_yojson : t -> Yojson.Safe.t;;
end;;

module type Error_value = sig
  type t;;
  val equal : t -> t -> bool;;
  val pp : t Pp_utils.pretty_printer;;
  val show : t -> string;;
  val to_yojson : t -> Yojson.Safe.t;;
end;;

module type Error_binop = sig
  type t;;
  val equal : t -> t -> bool;;
  val pp : t Pp_utils.pretty_printer;;
  val show : t -> string;;
  val to_yojson : t -> Yojson.Safe.t;;
end;;

module type Error_type = sig
  type t;;
  val equal : t -> t -> bool;;
  val subtype : t -> t -> bool;;
  val pp : t Pp_utils.pretty_printer;;
  val show : t -> string;;
  val to_yojson : t -> Yojson.Safe.t;;
end;;

(* **** Natodefa modules **** *)

let replace_linebreaks (str : string) : string =
  String.replace_chars
    (function '\n' -> " " | c -> String.of_char c) str
;;

module Ident : (Error_ident with type t = On_ast.ident) = struct
  type t = On_ast.ident;;
  let equal = On_ast.equal_ident;;
  let pp = On_ast_pp.pp_ident;;
  let show = On_ast_pp.show_ident;;
  let to_yojson ident =
    `String (replace_linebreaks @@ show ident);;
end;;

module Value : (Error_value with type t = On_ast.expr) = struct
  type t = On_ast.expr;;
  let equal = On_ast.equal_expr;;
  let pp = On_ast_pp.pp_expr;;
  let show = On_ast_pp.show_expr;;
  let to_yojson value =
    `String (replace_linebreaks @@ show value);;
end;;

module Binop : (Error_binop with type t = On_ast.expr) = struct
  type t = On_ast.expr;;
  let equal = On_ast.equal_expr;;
  let pp = On_ast_pp.pp_expr;;
  let show = On_ast_pp.show_expr;;
  let to_yojson binop =
    `String (replace_linebreaks @@ show binop);;
end;;

module Type : (Error_type with type t = On_ast.type_sig) = struct
  type t = On_ast.type_sig;;
  let equal = On_ast.equal_type_sig;;
  let subtype _ _ = false;;
  let pp = On_ast_pp.pp_on_type;;
  let show = On_ast_pp.show_on_type;;
  let to_yojson typ =
    `String (replace_linebreaks @@ show typ);;
end;;

module On_error = Error.Make(Ident)(Value)(Binop)(Type);;

(* **** Odefa error cleanup **** *)

let odefa_error_remove_instrument_vars
    (odefa_on_maps : On_to_odefa_maps.t)
    (error : Error.Odefa_error.t)
  : Error.Odefa_error.t =
  let remove_instrument_aliases aliases =
    List.filter
      (fun alias ->
        not @@ On_to_odefa_maps.is_var_instrumenting odefa_on_maps alias)
      aliases
  in
  match error with
  | Error_binop err ->
    begin
      let left_aliases' =
        remove_instrument_aliases err.err_binop_left_aliases
      in
      let right_aliases' =
        remove_instrument_aliases err.err_binop_right_aliases
      in
      let (_, op, _) =
        err.err_binop_operation
      in
      let l_operand' =
        match left_aliases' with
        | [] -> err.err_binop_left_val
        | v :: _ -> Ast.Var_body (Var (v, None))
      in
      let r_operand' =
        match right_aliases' with
        | [] -> err.err_binop_right_val
        | v :: _ -> Ast.Var_body (Var (v, None))
      in
      Error_binop {
        err with
        err_binop_left_aliases = left_aliases';
        err_binop_right_aliases = right_aliases';
        err_binop_operation = (l_operand', op, r_operand')
      }
    end
  | Error_match err ->
    begin
      let match_aliases = err.err_match_aliases in
      Error_match {
        err with
        err_match_aliases = remove_instrument_aliases match_aliases;
      }
    end
  | Error_value err ->
    begin
      let aliases = err.err_value_aliases in
      Error_value {
        err with
        err_value_aliases = remove_instrument_aliases aliases;
      }
    end
;;

(* **** Odefa to natodefa error translation **** *)

(* Helper function to remove adjacent duplicate entries in a list (note that
   this does not remove non-adjacent dupes). *)
let deduplicate_list list =
  List.fold_right
    (fun x deduped_list ->
      match List.Exceptionless.hd deduped_list with
      | Some next ->
        let is_next = On_ast.equal_ident next x in
        if is_next then deduped_list else x :: deduped_list
      | None ->
        x :: deduped_list
    )
    list
    []
;;

(* Helper function that returns a natodefa binop, depending on the odefa
   binary operator. *)
let odefa_to_on_binop (odefa_binop : Ast.binary_operator) :
    On_ast.core_natodefa -> On_ast.core_natodefa -> On_ast.core_natodefa =
  match odefa_binop with
  | Ast.Binary_operator_plus ->
      fun e1 e2 -> On_ast.Plus (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_minus ->
      fun e1 e2 -> On_ast.Minus (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_times ->
      fun e1 e2 -> On_ast.Times (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_divide ->
      fun e1 e2 -> On_ast.Divide (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_modulus ->
      fun e1 e2 -> On_ast.Modulus (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_equal_to ->
      fun e1 e2 -> On_ast.Equal (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_not_equal_to ->
      fun e1 e2 -> On_ast.Neq (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_less_than ->
      fun e1 e2 -> On_ast.LessThan (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_less_than_or_equal_to ->
      fun e1 e2 -> On_ast.Leq (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_and ->
      fun e1 e2 -> On_ast.And (new_expr_desc e1, new_expr_desc e2)
  | Ast.Binary_operator_or ->
      fun e1 e2 -> On_ast.Or (new_expr_desc e1, new_expr_desc e2)

let rec replace_type (t_desc : syn_natodefa_edesc) (new_t : syn_natodefa_edesc)
    (tag : int) : syn_natodefa_edesc =
  let cur_tag = t_desc.tag in
  let t = t_desc.body in
  if tag = cur_tag
  then
    (* (print_endline "tag matched!");
       (print_endline @@ On_to_odefa.show_expr_desc new_t); *)
    new_t
  else
    let transform_funsig (Funsig (fid, args, fe_desc)) =
      Funsig (fid, args, replace_type fe_desc new_t tag)
    in
    let t' =
      match t with
      | Int _ | Bool _ | Var _ | Input | TypeError _ | Untouched _ -> t
      | Function (args, fe_desc) ->
          Function (args, replace_type fe_desc new_t tag)
      | Appl (ed1, ed2) ->
          Appl (replace_type ed1 new_t tag, replace_type ed2 new_t tag)
      | Let (x, ed1, ed2) ->
          Let (x, replace_type ed1 new_t tag, replace_type ed2 new_t tag)
      | LetRecFun (funsigs, e_desc) ->
          let funsigs' = List.map transform_funsig funsigs in
          let e_desc' = replace_type e_desc new_t tag in
          LetRecFun (funsigs', e_desc')
      | LetFun (funsig, e_desc) ->
          let funsig' = transform_funsig funsig in
          let e_desc' = replace_type e_desc new_t tag in
          LetFun (funsig', e_desc')
      | LetWithType (x, e1_desc, e2_desc, e3_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          let e3_desc' = replace_type e3_desc new_t tag in
          LetWithType (x, e1_desc', e2_desc', e3_desc')
      | LetRecFunWithType (funsigs, e_desc, ts) ->
          let funsigs' = List.map transform_funsig funsigs in
          let e_desc' = replace_type e_desc new_t tag in
          let ts' = List.map (fun ed -> replace_type ed new_t tag) ts in
          LetRecFunWithType (funsigs', e_desc', ts')
      | LetFunWithType (funsig, e_desc, t) ->
          let funsig' = transform_funsig funsig in
          let e_desc' = replace_type e_desc new_t tag in
          let t' = replace_type t new_t tag in
          LetFunWithType (funsig', e_desc', t')
      | Plus (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Plus (e1_desc', e2_desc')
      | Minus (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Minus (e1_desc', e2_desc')
      | Times (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Times (e1_desc', e2_desc')
      | Divide (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Divide (e1_desc', e2_desc')
      | Modulus (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Modulus (e1_desc', e2_desc')
      | Equal (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Equal (e1_desc', e2_desc')
      | Neq (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Neq (e1_desc', e2_desc')
      | LessThan (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          LessThan (e1_desc', e2_desc')
      | Leq (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Leq (e1_desc', e2_desc')
      | GreaterThan (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          GreaterThan (e1_desc', e2_desc')
      | Geq (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Geq (e1_desc', e2_desc')
      | And (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          And (e1_desc', e2_desc')
      | Or (e1_desc, e2_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          Or (e1_desc', e2_desc')
      | Not e_desc ->
          let e_desc' = replace_type e_desc new_t tag in
          Not e_desc'
      | If (e1_desc, e2_desc, e3_desc) ->
          let e1_desc' = replace_type e1_desc new_t tag in
          let e2_desc' = replace_type e2_desc new_t tag in
          let e3_desc' = replace_type e3_desc new_t tag in
          If (e1_desc', e2_desc', e3_desc')
      | Record ed_map ->
          let ed_map' =
            Ident_map.map (fun ed -> replace_type ed new_t tag) ed_map
          in
          Record ed_map'
      | RecordProj (e_desc, l) ->
          let e_desc' = replace_type e_desc new_t tag in
          RecordProj (e_desc', l)
      | Match (me_desc, ped_lst) ->
          let me_desc' = replace_type me_desc new_t tag in
          let ped_lst' =
            List.map (fun (p, ped) -> (p, replace_type ped new_t tag)) ped_lst
          in
          Match (me_desc', ped_lst')
      | VariantExpr (vl, e_desc) ->
          let e_desc' = replace_type e_desc new_t tag in
          VariantExpr (vl, e_desc')
      | List ts ->
          let ts' = List.map (fun t -> replace_type t new_t tag) ts in
          List ts'
      | ListCons (hd_desc, tl_desc) ->
          let hd_desc' = replace_type hd_desc new_t tag in
          let tl_desc' = replace_type tl_desc new_t tag in
          ListCons (hd_desc', tl_desc')
      | Assert e_desc ->
          let e_desc' = replace_type e_desc new_t tag in
          Assert e_desc'
      | Assume e_desc ->
          let e_desc' = replace_type e_desc new_t tag in
          Assume e_desc'
      | TypeUntouched _ | TypeVar _ | TypeInt | TypeBool -> t
      | TypeRecord td_map ->
          let td_map' =
            Ident_map.map (fun td -> replace_type td new_t tag) td_map
          in
          TypeRecord td_map'
      | TypeList td ->
          let td' = replace_type td new_t tag in
          TypeList td'
      | TypeArrow (td1, td2) ->
          let td1' = replace_type td1 new_t tag in
          let td2' = replace_type td2 new_t tag in
          TypeArrow (td1', td2')
      | TypeArrowD ((tid, td1), td2) ->
          let td1' = replace_type td1 new_t tag in
          let td2' = replace_type td2 new_t tag in
          TypeArrowD ((tid, td1'), td2')
      | TypeSet (td, pred) ->
          let td' = replace_type td new_t tag in
          let pred' = replace_type pred new_t tag in
          TypeSet (td', pred')
      | TypeUnion (td1, td2) ->
          let td1' = replace_type td1 new_t tag in
          let td2' = replace_type td2 new_t tag in
          TypeUnion (td1', td2')
      | TypeIntersect (td1, td2) ->
          let td1' = replace_type td1 new_t tag in
          let td2' = replace_type td2 new_t tag in
          TypeIntersect (td1', td2')
      | TypeRecurse (tv, td) ->
          let td' = replace_type td new_t tag in
          TypeRecurse (tv, td')
    in
    { tag = cur_tag; body = t' }

let odefa_to_natodefa_error (odefa_on_maps : On_to_odefa_maps.t)
    (ton_on_maps : Ton_to_on_maps.t)
    (err_loc_option : On_ast.syn_natodefa_edesc option)
    (actual_aliases : Ast.ident list)
    (err_vals_map : Ast.value On_ast.Ident_map.t)
    (odefa_err : Error.Odefa_error.t) : On_error.t =
  (* Helper functions *)
  let odefa_to_on_expr =
    On_to_odefa_maps.get_natodefa_equivalent_expr odefa_on_maps
  in
  let odefa_to_on_aliases (aliases : Ast.ident list) : On_ast.ident list =
    aliases
    |> List.filter_map
      (fun alias ->
        match (odefa_to_on_expr alias).body with
        | (On_ast.Var ident) -> Some ident
        | _ -> None
      )
    (* During translation, some odefa vars are assigned to the same natodefa
       vars (namely in var expressions).  The following procedure removes any
       adjacent duplicates from the alias chain. *)
    |> deduplicate_list
  in
  let odefa_to_on_value (aliases : Ast.ident list) : On_ast.expr_desc =
    let last_var =
      try
        List.last aliases
      with Invalid_argument _ ->
        raise @@ Jhupllib.Utils.Invariant_failure "Can't have empty alias list!"
    in
    odefa_to_on_expr last_var
  in
  let odefa_to_on_type (typ : Ast.type_sig) : On_ast.type_sig =
    match typ with
    | Ast.Top_type -> TopType
    | Ast.Int_type -> IntType
    | Ast.Bool_type -> BoolType
    | Ast.Fun_type -> FunType
    | Ast.Rec_type lbls ->
      On_to_odefa_maps.get_type_from_idents odefa_on_maps lbls
    | Ast.Bottom_type ->
      raise @@ Jhupllib.Utils.Invariant_failure
        (Printf.sprintf "Bottom type not in natodefa")
  in
  (* Odefa to natodefa *)
  match odefa_err with
  | Error.Odefa_error.Error_binop err ->
    begin
      let l_aliases = err.err_binop_left_aliases in
      let r_aliases = err.err_binop_right_aliases in
      let l_aliases_on = odefa_to_on_aliases l_aliases in
      let r_aliases_on = odefa_to_on_aliases r_aliases in
      let (_, op, _) = err.err_binop_operation in
      let l_value = odefa_to_on_value l_aliases in
      let r_value = odefa_to_on_value r_aliases in
      let constraint_expr =
        let left_expr =
          if List.is_empty l_aliases_on then l_value.body else
            On_ast.Var (List.hd l_aliases_on)
        in
        let right_expr =
          if List.is_empty r_aliases_on then r_value.body else
            On_ast.Var (List.hd r_aliases_on)
        in
        odefa_to_on_binop op left_expr right_expr
      in
      Error_binop {
        err_binop_left_aliases = l_aliases_on;
        err_binop_right_aliases = r_aliases_on;
        err_binop_left_val = l_value.body;
        err_binop_right_val = r_value.body;
        err_binop_operation = constraint_expr;
      }
    end
  | Error.Odefa_error.Error_match err ->
    begin
      let aliases = err.err_match_aliases in
      Error_match {
        err_match_aliases = odefa_to_on_aliases aliases;
        err_match_val = (odefa_to_on_value aliases).body;
        err_match_expected = odefa_to_on_type err.err_match_expected;
        err_match_actual = odefa_to_on_type err.err_match_actual;
      }
    end
  | Error.Odefa_error.Error_value err ->
    begin
      let aliases = err.err_value_aliases in
      Error_value {
        err_value_aliases = odefa_to_on_aliases aliases;
        err_value_val = (odefa_to_on_value aliases).body;
      }
    end
;;