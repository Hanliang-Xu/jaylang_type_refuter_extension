open Core
open Dj_common
open Jayil.Ast

module Deprecated :
  sig
    (**
      The eval session tracks everything needed by the interpreter to evaluate the expression.
      Nothing here is used for any part of the concolic logic. This is all to correctly evaluate
      the expression.
    *)
    module Eval :
      sig
        module Mode :
          sig
            type t =
              | Plain
              | With_target_x of Id.t
              | With_full_target of Id.t * Concrete_stack.t

            module Debug :
              sig
                type t =
                  | No_debug
                  | Debug_clause of (Id.t -> Concrete_stack.t -> value -> unit)
              end
          end

        module G : (* = Graph.Imperative.Digraph.ConcreteBidirectional (Id_with_stack) *) (* hide until can find type *)
          sig
            type t
          end

        (* NOTE: this type is mutable *)
        type t =
          { (* mode *)
            input_feeder    : Input_feeder.t
          ; mode            : Mode.t
          ; (* tuning *)
            step            : int ref
          ; max_step        : int option
          ; (* book-keeping*)
            alias_graph     : G.t
          ; (* debug *)
            is_debug        : bool
          ; debug_mode      : Mode.Debug.t
          ; val_def_map     : (Id_with_stack.t, clause_body * Dvalue.t) Hashtbl.t
          ; term_detail_map : (Lookup_key.t, Lookup_detail.t) Hashtbl.t
          ; block_map       : Cfg.block Jayil.Ast.Ident_map.t
          ; rstk_picked     : (Rstack.t, bool) Hashtbl.t
          ; lookup_alert    : Lookup_key.t Hash_set.t } 

        val create_default : unit -> t
        (** [create_default ()] is an arbitrary session with no intentional input feeder and empty graphs. *)

        (* val create : ?max_step:int -> ?debug_mode:Mode.Debug.t -> Global_state.t -> Global_config.t -> Mode.t -> Input_feeder.t -> t *)
        val create : Input_feeder.t -> int -> t
        (** [create input_feeder global_max_step] *)

        val add_alias : Id_with_stack.t -> Id_with_stack.t -> t -> unit
        (** [add_alias x y session] sets the alias graph in the given [session] to say that
            [x] is now an alias of [y]. [x] is defined *after* [y] and points to [y]. *)

        val add_val_def_mapping : Id_with_stack.t -> (clause_body * Dvalue.t) -> t -> unit
        (** [add_val_def_mapping x (body, v) session] sets the identifier [x] to hold the value [v]
            that is evaluated from the clause body [body] in the given [session]. *)
      end

    (**
      The concolic session tracks a single concolic evaluation. It gathers formulas from start to finish
      of one evaluation of the program.   
    *)
    module Concolic :
      sig
        type t

        val add_formula : t -> Z3.Expr.expr -> t
        (** [add_formula session expr] adds the [expr] under the current parent of the [session]. *)

        val add_key_eq_val : t -> Lookup_key.t -> Jayil.Ast.value -> t
        (** [add_key_eq_val session k v] sets [k = v] in the [session]. This is a special case of [add_formula]. *)

        val add_alias : t -> Lookup_key.t -> Lookup_key.t -> t
        (** [add_alias session x y] sets [x = y] in the [session]. This is a special case of [add_formula]. *)

        val add_binop : t -> Lookup_key.t -> Jayil.Ast.binary_operator -> Lookup_key.t -> Lookup_key.t -> t
        (** [add_binop session x op y z] sets [z = y op z] in the [session]. This is a special case of [add_formula]. *)

        val found_abort : t -> t
        (** [found_abort session] adds the info that an abort was found under the current parent. *)

        val reach_max_step : t -> t
        (** [reach_max_step session] adds the info that the max step was reached under the current parent. *)

        val fail_assume : t -> Lookup_key.t -> t
        (** [fail_assume session x] quits the session because the assume statement failed.
            The info is added that the condition [x] must be true. *)

        val enter_branch : t -> Branch.Runtime.t -> t
        (** [enter_branch session branch] sets the new parent as [branch] and hits the branch. *)

        val exit_branch : t -> t
        (** [exit_branch session ret_key] uses the final key [ret_key] in the branch to exit and return
            to previous parent. Also cleans up formulas in the solver. *)

        val add_input : t -> Lookup_key.t -> Dvalue.t -> t
        (** [add_input session x v] adds the fact that [v] was fed to variable [x] as an input. *)
      end

    type t 
    (** [t] tracks information between runs of the concolic evaluator and helps create new Eval and Concolic
        sessions for future runs. *)

    val default : t
    (** [default] is a session to be used to make the first run of the concolic evaluator. *)

    val with_options : ?solver_timeout_sec:float -> ?global_max_step:[ `Const of int | `Scale of float ] -> ?quit_on_first_abort:bool -> t -> t

    val set_quit_on_first_abort : t -> bool -> t
    (** [set_quit_on_first_abort session b] sets the [session] to quit when the first abort is hit iff [b] is true. *)

    val of_expr : Jayil.Ast.expr -> t
    (** [of_expr expr] has the AST branches loaded from [expr] into [default]. *)

    val next : t -> [ `Done of t | `Next of t * Concolic.t * Eval.t ] Lwt.t
    (** [next session] is [`Done session'] when there is no satisfiable or unhit target left in [session'],
        or it is a new session with a concolic session and eval session to try to hit the top target. *)

    val finish : t -> t
    (** [finish session] is [session] with the finished branch store (i.e. unhit branches set as unreachable). *)

    val print : t -> unit
    (** [print session] prints the branch store. *)

    val accum_concolic : t -> Concolic.t -> t
    (** [accum_concolic session concolic_session] is a new session that merges the results of [concolic_session] into
        [session]. The new session is then ready to be called with [next] to begin another run. *)

    val branch_tracker : t -> Branch_tracker.t
    (** [branch_tracker session] is the statuses of the branches in the session. *)
  end

(*
  --------------
  END DEPRECATED   
  --------------
*)

module Concrete = Deprecated.Eval

module Symbolic :
  sig
    type t
    (** [t] tracks symbolic representations of the program during interpretation. *)

    val empty : t
    (** [empty] is a default symbolic session. *)

    val with_options : (t -> t) Concolic_options.Fun.t
    (** [with_options t] is [t] configured with the optional arguments. *)

    (*
      -----------
      EXPRESSIONS
      -----------
    *)

    val add_key_eq_val : t -> Lookup_key.t -> Jayil.Ast.value -> t
    (** [add_key_eq_val t k v] adds the formula that [k] has value [v] in [t]. *)

    val add_alias : t -> Lookup_key.t -> Lookup_key.t -> t
    (** [add_alias t k k'] adds the formula that [k] and [k'] hold the same value in [t]. *)

    val add_binop : t -> Lookup_key.t -> Jayil.Ast.binary_operator -> Lookup_key.t -> Lookup_key.t -> t
    (** [add_binop t x op left right] adds the formula that [x = left op right] in [t]. *)

    val add_input : t -> Lookup_key.t -> Dvalue.t -> t
    (** [add_input t x v] is [t] that knows input [x = v] was given. *)

    val add_not : t -> Lookup_key.t -> Lookup_key.t -> t
    (** [add_not t x y] adds [x = not y] to [t]. *)

    val add_match : t -> Lookup_key.t -> Lookup_key.t -> Jayil.Ast.pattern -> t
    (** [add_match t x y pat] adds [x = y ~ pat] to [t]. *)

    (*
      -----------------
      CONTROL FLOW ETC.
      -----------------
    *)

    val hit_branch : t -> Branch.Runtime.t -> t
    (** [hit_branch t branch] is [t] that knows [branch] has been hit during interpretation. *)

    val fail_assume : t -> Lookup_key.t -> t
    (** [fail_assume t key] tells [t] that the variable in [key] was false when it was assumed to be true. *)

    val found_abort : t -> t
    (** [found_abort t] tells [t] that an abort was found in interpretation. *)

    val reach_max_step : t -> t
    (** [reach_max_step t] tells [t] that the max interpretation step was hit, and interpretation stopped. *)
  end

type t

val empty : t
(** [empty] is a default path tracker with no target and empty tree and stack. *)

val with_options : (t -> t) Concolic_options.Fun.t

val of_expr : Jayil.Ast.expr -> t
(** [of_expr expr] is [empty] that knows of all branches in the [expr]. *)

val accum_symbolic : t -> Symbolic.t -> t
val next : t -> [ `Done of Branch_info.t | `Next of (t * Concrete.t) ]

val branch_info : t -> Branch_info.t
(** [branch_info t] is the branch info in [t]. *)

val run_num : t -> int
(** [run_num t] is the number of interpretations [t] has done. *)