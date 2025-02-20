(**
  File: expression.mli
  Purpose: represent expressions for symbolic values

  Detailed description:
    This module builds and simplifies expressions from
    constants, keys, and operations.

    It simplifies constant expressions to be smaller.

    Given a Z3 interface, it converts expressions to Z3
    formulas.

  Dependencies:
    Z3_intf -- is the destination of expressions
    Stepkey -- keys represent unconstrained symbolic inputs
*)

module Typed_binop : sig
  type iii = int * int * int
  type iib = int * int * bool
  type bbb = bool * bool * bool

  type _ t =
    | Plus : iii t
    | Minus : iii t
    | Times : iii t
    | Divide : iii t
    | Modulus : iii t
    | Less_than : iib t
    | Less_than_eq : iib t
    | Greater_than : iib t
    | Greater_than_eq : iib t
    | Equal_int : iib t
    | Equal_bool : bbb t
    | Not_equal : iib t
    | And : bbb t
    | Or : bbb t
end

type 'a t
(** ['a t] is a symbolic expression. *)

val is_const : 'a t -> bool
(** [is_const e] is true if and only if the expression is purely constant.
    That is, there are no symbolic components in it. *)

val true_ : bool t
(** [true_] is the constant expression representing [true]. *)

val false_ : bool t
(** [false_] is the constant expression representing [false]. *)

val const_int : int -> int t
(** [const_int i] is the constant expression representing the constant int [i]. *)

val const_bool : bool -> bool t
(** [const_bool b] is the constant expression representing the constant bool [b]. *)

val key : 'a Stepkey.t -> 'a t
(** [key k] is a symbolic expression for the key [k]. *)

val not_ : bool t -> bool t
(** [not_ e] negates the expression [e]. *)

val op : 'a t -> 'a t -> ('a * 'a * 'b) Typed_binop.t -> 'b t
(** [op e1 e2 binop] is an expression for the result of the binary operation [binop]
    on [e1] and [e2]. *)

module Solve (Expr : Z3_intf.S) : sig
  val to_formula : 'a t -> 'a Expr.t
  (** [to_formula e] is a Z3 formula equivalent to [e]. *)
end
