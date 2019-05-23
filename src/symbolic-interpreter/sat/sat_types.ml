(** This module contains data types for the SAT solving process used by
    symbolic interpretation. *)

open Odefa_ast;;

open Ast;;
open Ast_pp;;
open Interpreter_types;;

(** The type of right-hand sides of formulae generated during symbolic
    interpretation. *)
type formula_expression =
  | Formula_expression_binop of symbol * binary_operator * symbol
  | Formula_expression_pattern_match of symbol * pattern
  | Formula_expression_alias of symbol
  | Formula_expression_value of value
[@@deriving eq, ord, show]
;;

(** The type of formulae which are generated during symbolic interpretation. *)
type formula =
  | Formula of symbol * formula_expression
[@@deriving eq, ord, show]
;;

module Formula_expression = struct
  type t = formula_expression [@@deriving eq, ord, show];;
end;;

module Formula = struct
  type t = formula [@@deriving eq, ord, show];;
end;;
