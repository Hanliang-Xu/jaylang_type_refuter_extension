
module Make : functor (_ : Solve.S) (_ : Target_queue.S) (P : Pause.S) (_ : Options.V) -> sig
  type t

  val empty : t
  (** [empty] knows no path or constraints *)

  val add_stem : t -> Stem.t -> t
  (** [add_stem tree stem] is a new path tree where the [stem] has been placed onto the [tree]. *)

  val pop_sat_target : t -> (t * Target.t * Input_feeder.t) option P.t
  (** [pop_sat_target tree] is a new tree, target, and input feeder to hit that target, or
      is none if there are not satisfiable targets left in the [tree]. *)
end
