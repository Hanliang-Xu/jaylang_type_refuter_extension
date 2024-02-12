
type t

val empty : t
(** [empty] is a default path tracker with no target and empty tree and stack. *)

val with_options : ?quit_on_abort:bool -> ?solver_timeout_s:float -> t -> t

val of_expr : Jayil.Ast.expr -> t

val add_formula : t -> Z3.Expr.expr -> t

val add_key_eq_val : t -> Lookup_key.t -> Jayil.Ast.value -> t
(** [add_key_eq_val t k v] adds the formula that [k] has value [v] in the top node of [t]. *)

val add_alias : t -> Lookup_key.t -> Lookup_key.t -> t
(** [add_alias t k k'] adds the formula that [k] and [k'] hold the same value in the top node of [t]. *)

val add_binop : t -> Lookup_key.t -> Jayil.Ast.binary_operator -> Lookup_key.t -> Lookup_key.t -> t
(** [add_binop t x op left right] adds the formula that [x = left op right] to the the top node of [t]. *)

val add_input : t -> Lookup_key.t -> Dvalue.t -> t
(** [add_input t x v] is [t] that knows input [x = v] was given. *)

val hit_branch : t -> Branch.Runtime.t -> t
(** [hit_branch t branch] is [t] that knows [branch] has been hit during interpretation. *)

val next : t -> [ `Done of Branch_tracker.Status_store.Without_payload.t | `Next of (t * Session.Eval.t) ]
(** [next t] is a path tracker intended to hit the most prioritized target after the run in [t]. *)

val status_store : t -> Branch_tracker.Status_store.Without_payload.t

val fail_assume : t -> Lookup_key.t -> t
val found_abort : t -> t