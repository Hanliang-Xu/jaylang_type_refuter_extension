(**
   Contains data type definitions for the AST of the *nested* toy language.
*)

open Ast;;

(** Expressions in the nested language. *)
type expr =
  | Record_expr of expr Ident_map.t
  | Function_expr of function_value
  | Ref_expr of expr
  | Var_expr of var
  | Appl_expr of expr * expr
  | Conditional_expr of expr * pattern * function_value * function_value
  | Deref_expr of expr
  | Update_expr of expr * expr
  | Let_expr of var * expr * expr
  | Projection_expr of expr * ident

(** Function values in the nested language. *)
and function_value =
  | Function of var * expr

(** Patterns in the nested language. *)
and pattern =
  | Record_pattern of pattern Ident_map.t
;;