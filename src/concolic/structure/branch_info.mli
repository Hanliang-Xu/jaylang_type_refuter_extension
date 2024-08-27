
module Status :
  sig
    type t = 
      | Found_abort of Jil_input.t list (* inputs in the reverse order they're given. payload ignored on compare *)
      | Type_mismatch of (Jayil.Ast.Ident_new.t * Jil_input.t list) (* ^ *)
      | Hit
      | Unknown
      | Unhit
      [@@deriving compare, sexp]

    val to_string : t -> string
    (** [to_string t] does not show the inputs if [t] is [Found_abort _]. *)
  end

type t [@@deriving compare, sexp]

val empty : t

val of_expr : Jayil.Ast.expr -> t

val to_string : t -> string

val set_branch_status : new_status:Status.t -> t-> Branch.Or_global.t -> t

val contains : t -> Status.t -> bool

val merge : t -> t -> t

val find : t -> f:(Branch.Or_global.t -> Status.t -> bool) -> (Branch.Or_global.t * Status.t) option

val get_hit_count : t -> Branch.t -> int