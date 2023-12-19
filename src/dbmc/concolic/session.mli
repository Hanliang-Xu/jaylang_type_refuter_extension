open Core
open Dj_common
open Jayil.Ast
open Concolic_exceptions

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

module Eval :
  sig
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
        is_debug        : bool (* TODO: get rid of this *) (* can use Mode.Debug.t instead *)
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

module Concolic :
  sig

    module Permanent_formulas :
      sig
        type t
      end
    (*
      The concolic session contains an eval session, which is mutable.
      So the concolic session needs to get passed along for the branch
      and formula stores, but it can pass in its eval session to be mutated.   

      It is expected that a concolic session is used during a single evaluation
      of the program expression. It is then sent to the "next" session for the
      next evaluation (which tries to target a different branch).
    *)
    type t =
      { branch_store       : Branch.Status_store.t 
      ; formula_store      : Branch_solver.t
      ; permanent_formulas : Permanent_formulas.t
      ; target_stack       : Branch.Runtime.t list
      ; prev_sessions      : t list
      ; global_max_step    : int
      ; run_num            : int 
      ; eval               : Eval.t } 

    val create_default : unit -> t
    (** [create_default ()] is a concolic session with empty stores, no target, run_num 0, and
        a default eval session *)

    val revert : t -> [ `Abort_before_target | `Max_step_before_target of Branch.Runtime.t ] -> t option

    val next : t -> [ `Next of t | `Done of Branch.Status_store.t]
    (** [next session] is a session for the next run that has a resets formulas, keeps the top target
        (unless it is unsatisfiable), and has an eval session whose input feeder is intended to hit
        the (next satisfiable) target. If there are no more satisfiable branches, then it is the branch
        store. *)

    val load_branches : t -> expr -> t
    (** [load_branches session expr] is a copy of [session] and has all AST branches from [expr] as
        unhit branches in the branch_store. *)

    val check_target_hit : t -> Branch.Runtime.t option -> bool
    (** [check_target_hit session target_opt] is [b] where [b] is true if and only if the
        target is hit in the session's branch store. *)

    val finish_and_print : t -> unit
    (** [finish_and_print session] prints the branch store where all previously unhit branches are
        marked as unsatisfiable. *)

    (* TODO: just make mutable fields and assign to those. No point in copying all of them while using a ref cell.
        Actually maybe the point is because I want to be able to copy previous sessions without them getting
        mutated. I should see how changing the fields works when two sessions share a field. *)
    module Ref_cell :
      sig
        (* This module holds wrappers to access the solver/store in a concolic session ref cell. *)

        val hit_branch : ?new_status:Branch.Status.t -> t ref -> Branch.Runtime.t -> unit
        (** [hit_branch session branch] assigns a new session to the [session] cell that contains
            all the same fields as before, but the branch store now has the given [branch] as hit,
            or has the given optional status. *)

        val add_key_eq_val : t ref -> Branch_solver.Parent.t -> Lookup_key.t -> value -> unit
        (** [add_key_eq_val session parent key v] assigns a new session to the [session] cell that contains
            all the same fields as before, but the formula store gains the formula that the [key] equals
            the given value [v]. *)

        val add_formula : t ref -> Lookup_key.t list -> Branch_solver.Parent.t -> Z3.Expr.expr -> unit
        (** [add_formula session deps parent expr] assigns a new session to the [session] cell
            that contains all the same fields as before, but the formula store gains the given formula
            [expr] under the [parent], and the formula also depends on [deps]. *)

        val add_siblings : t ref -> Lookup_key.t -> Lookup_key.t list -> unit
        (** [add_siblings session child_key siblings] adds all dependencies of siblings to the child_key. *)

        val update_target_branch : t ref -> Branch.Runtime.t -> unit
        (** [update_target_branch session branch_key branch] will update the target branch to the other direction of
            the given [branch] that was just hit. If the other direction has already been hit, then nothing is
            updated. The [branch_key] is the variable in the clause for the [branch].

            TODO: consider just passing in the target that was just hit
            
            This way, when this is called during a concolic evaluation, the target branch after the call will
            be the deepest branch whose other side has been hit, and nothing under the other side is unhit.
            
            This ensures that when moving on from a branch, we've fully used all the information we can to hit
            everything in it. For sake of argument, suppose we target outermost branches first. Say the true side of the
            outer branch has a lot of internal branches, and we hit it first. The false side is then our target, and say it
            has no internal branches. The false side is hit easily, and then we must try to hit internal branches of
            the true side; we have no information to target these branches. For this reason, we target deeper
            branches first.
            
            outer_branch = outer_branch_condition ?
              (
                (* true side. Say it is hit first *)
                (* lots of internal branches *)
              ) :
              (
                (* false side. It is the target of the next run after hitting the first *)
                (* no internal branches *)
              )
            
            So in this program, we hit the true side, and then the false side, and then need to dive back into the
            true side but have no information to help us do so because we have only kept information from the false
            side.
            *)

        val exit_branch : t ref -> Branch_solver.Parent.t -> Branch.Runtime.t -> Lookup_key.t -> unit
        (** TODO *)
      end
  end

module Concolic2 :
  sig
    module Outcome :
      sig
        type t =
          | Hit_target
          | Found_abort
          | Reach_max_step
      end

    type t =
      { branch_solver : Branch_solver.t
      ; cur_parent    : Branch_solver.Parent.t
      ; parent_stack  : Branch_solver.Parent.t list (* previous parents to revert back to when exiting branches *)
      ; cur_target    : Branch.Runtime.t option
      ; new_targets   : Branch.Runtime.t list
      ; outcomes      : Outcome.t list (* Note: it's possible to hit the target and reach abort later, so we need multiple outcomes *)
      ; hit_branches  : Branch.Ast_branch.t list (* may want to annotate with inputs as of hitting the branch *)
      ; inputs        : (Ident.t * Dvalue.t) list }

    val add_formula : t -> Z3.Expr.expr -> t
    (** [add_formula session expr] adds the [expr] under the current parent of the [session]. *)

    val add_key_eq_val : t -> Lookup_key.t -> Jayil.Ast.value -> t
    (** [add_key_eq_val session k v] sets [k = v] in the [session]. This is a special case of [add_formula]. *)

    val add_siblings : t -> Lookup_key.t -> siblings:Lookup_key.t list -> t
    (** [add_siblings session key siblings] adds all dependencies of [siblings] to the [key] so that the
        [key] also depends on them.
        
        NOTE: I think this is not needed anymore. *)

    val enter_branch : t -> Branch.Runtime.t -> t
    (** [enter_branch session branch] sets the new parent as [branch] and hits the branch. *)
    (* TODO: If I'd like this to hit the branch, it needs to access the full session. *)

    val exit_branch : t -> Lookup_key.t -> t
    (** [exit_branch session ret_key] uses the final key [ret_key] in the branch to exit and return
        to previous parent. Also cleans up formulas in the solver. *)

    val add_input : t -> Ident.t -> Dvalue.t -> t
    (** [add_input session x v] adds the fact that [v] was fed to variable [x] as an input. *)
  end

module Target_stack :
  sig
    type t (* = (Branch_solver.t * Branch.Runtime.t) list *)
  end

type t = 
  { branch_store        : Branch.Status_store.t
  ; persistent_formulas : Branch_solver.Formula_set.t
  ; target_stack        : Target_stack.t
  ; global_max_step     : int
  ; run_num             : int }

val create_default : unit -> t
(** [create_default ()] is a session to be used for to make the first run of the concolic evaluator. *)

val load_branches : t -> Jayil.Ast.expr -> t
(** [load_branches session expr] has the AST branches loaded from [expr] into [session]. *)

val next : t -> [ `Done of t | `Next of t * Concolic2.t * Eval.t ]
(** [next session] is [`Done session'] when there is no satisfiable or unhit target left in [session'],
    or it is a new session with a concolic session and eval session to try to hit the top target. *)

(* val is_finished : t -> bool *)
(** [is_finished session] is true if there are no satisfiable or unhit targets left. *)

val finish : t -> t
(** [finish session] is [session] with the finished branch store (i.e. unhit branches set as unreachable). *)

val print : t -> unit
(** [print session] prints the branch store. *)

val accum_concolic : t -> Concolic2.t -> t

(* val hit_branch : ?new_status:Branch.Status.t -> t -> Branch.Runtime.t -> t *)
(** [hit_branch ~new_status session ast_branch] has the given [ast_branch] set with the [new_status].
    This may add to the persistent formulas if the status is abort. *)

(* val add_targets : t -> Branch.Runtime.t list -> Branch_solver.t -> t *)
(** [add_targets session target_list branch_solver] adds the [target_list] to the worklist to be later solved
    for using the given [branch_solver]. *)
