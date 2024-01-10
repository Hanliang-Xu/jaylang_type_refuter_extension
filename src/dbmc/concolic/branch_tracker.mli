module Input :
  sig
    type t = (Lookup_key.t * int) list
    (* [t] is the input for an entire run. A run can have multiple inputs *)
  end

module Status :
  sig
    type t =
      | Hit of Input.t list (* can be hit on multiple runs *)
      | Unhit
      | Unsatisfiable (* TODO: payload? *)
      | Found_abort of Input.t list
      | Reach_max_step of int (* counter for how many times it has reached max step *)
      | Missed
      | Unreachable_because_abort (* TODO: payload? *)
      | Unreachable_because_max_step (* ^ *)
      | Unknown
      | Unreachable

    val to_string : t -> string
  end

(*
  A `Status_store` tracks how AST branches are hit. It maps branch identifiers to their status.
*)
module Status_store :
  sig
    type t [@@deriving sexp, compare]
    (** [t] is a map from a branch identifier to the status of the branch. So it tells
        us whether the true and false direction of each branch have been hit. *)

    val empty : t
    (** [empty] has no information on any branches *)

    val of_expr : Jayil.Ast.expr -> t
    (** [of_expr expr] has all branches unhit that exist in the given [expr]. *)

    val print : t -> unit
    (** [print store] prints the statuses of all branches in the [store] to stdout. *)

    val add_branch_id : t -> Jayil.Ast.ident -> t
    (** [add_branch_id store id] is a new store where the identifier [id] has been added to
        the branch store [store], and both directions of the new branch are unhit. *)

    val get_unhit_branch : t -> Branch.t option
    (** [get_unhit_branch store] is some branch that is unhit. *)

    val set_branch_status : new_status:Status.t -> t -> Branch.t -> t
    (** [set_branch_status status store branch] is a new store where the given [branch] now has the
        [status]. All other branches are unaffected. *)

    val is_hit : t -> Branch.t -> bool
    (** [is_hit store branch] is true if and only if the status of [branch.branch_ident] in 
        the [store] has [branch.direction] as [Hit]. *)

    val get_status : t -> Branch.t -> Status.t
    (** [get_status store branch] is the status of the given [branch]. *)

    val find_branches : Jayil.Ast.expr -> t -> t
    (** [find_branches e store] is a new store where all the branches in the given expression [expr]
        have been added as unhit branches to the given [store]. *)

    val finish : t -> int -> t
    (** [finish store allowed_max_step] is a new store where all unhit branches are now marked as unsatisfiable. *)

  end

module Runtime :
  sig
    type t
    val empty : t
    val with_target : Branch.t -> t
    val hit_branch : t -> Branch.t -> t
    val exit_branch : t -> t
    val found_abort : t -> t
    val reach_max_step : t -> t
  end

type t

val empty : t
val of_expr : Jayil.Ast.expr -> t
val collect_runtime : t -> Runtime.t -> Input.t -> t
val set_unsatisfiable : t -> Branch.t -> t
val next_target : t -> Branch.t option * t
val get_aborts : t -> Branch.t list
val get_max_steps : t -> Branch.t list
val finish : t -> t
val print : t -> unit
val status_store : t -> Status_store.t