
module T :
  sig
    type t [@@deriving hash, compare, equal, sexp]
  end

type t = T.t [@@deriving hash, compare, equal, sexp]

val generate : Jayil.Ast.ident -> Fun_depth.t -> t
(** [generate id n] is the key for clause ident [id] that is at function depth [n]. *)

val to_string : t -> string

val x : t -> Jayil.Ast.ident
