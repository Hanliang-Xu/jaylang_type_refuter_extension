
open Core
open Lang.Ast

module Consts = struct
  type t =
    { target : Target.t
    ; options : Options.t
    ; input_feeder : Input_feeder.t }
end

module State = struct
  type t =
    { path : Path.t
    ; targets : Target.t list (* is a log in the semantics, but it's more efficient in state *)
    ; rev_inputs : Interp_common.Input.t list }

  let empty : t =
    { path = Path.empty
    ; targets = []
    ; rev_inputs = [] }

  let inputs ({ rev_inputs ; _ } : t) : Interp_common.Input.t list =
    List.rev rev_inputs
end

module Err = struct
  include Status.Eval
  let fail_on_nondeterminism_misuse (s : State.t) : t * State.t =
    Status.Found_abort (State.inputs s, "Nondeterminism used when not allowed."), s
  let fail_on_fetch (id : Ident.t) (s : State.t) : t * State.t =
    Status.Unbound_variable (State.inputs s, id), s
  let fail_on_max_step (_step : int) (s : State.t) : t * State.t =
    Status.Finished { pruned = true }, s
end

module M = struct
  include Interp_common.Effects.Make (State) (Value.Env) (Err)

  let abort (msg : string) : 'a m =
    let%bind s = get in
    fail (Status.Found_abort (State.inputs s, msg))

  let type_mismatch (msg : string) : 'a m =
    let%bind s = get in
    fail (Status.Type_mismatch (State.inputs s, msg))

  (*
    For efficiency, we don't use a writer but instead thread a state of accumulated targets.
  *)
  let[@inline always][@specialise] tell (targets : Target.t list) : unit m =
    modify (fun s -> { s with targets = targets @ s.targets })
end

module type S = sig
  type 'a m = 'a M.m
  val vanish : 'a m
  val incr_step : unit m
  val hit_branch : bool Direction.t -> bool Formula.t -> unit m
  val hit_case : int Direction.t -> int Formula.t -> other_cases:int list -> unit m
  val get_input : (Interp_common.Step.t -> 'a Input_feeder.Key.t) -> Value.t m
  val run : 'a m -> Status.Eval.t * Target.t list
end

module Initialize (C : sig val c : Consts.t end) (*: S*) = struct
  let max_step = C.c.options.global_max_step
  let max_depth = C.c.options.max_tree_depth
  let input_feeder = C.c.input_feeder
  let target = C.c.target

  type 'a m = 'a M.m

  open M

  let incr_step : unit m = incr_step ~max_step (* comes from M *)

  let vanish : 'a m =
    let%bind Step n = step in
    let%bind { path ; _ } = get in
    fail @@ Status.Finished { pruned = Path.length path > max_depth || n > max_step } 

  let push_branch_and_tell (type a) (dir : a Direction.t) (e : a Formula.t) 
      (make_tape : a Claim.t -> Path.t -> Target.t list) : unit m =
    if Formula.is_const e then return () else
    let%bind s = get in
    let n = Path.length s.path in
    if n >= max_depth then return () else
    let claim = Claim.Equality (e, dir) in
    let%bind () = modify (fun s' -> { s' with path = Path.cons (Claim.to_expression claim) s'.path }) in
    if n < Target.path_n target
    then return ()
    else tell (make_tape claim s.path)

  let hit_branch (dir : bool Direction.t) (e : bool Formula.t) : unit m =
    push_branch_and_tell dir e (fun claim path ->
      [ Target.make
        (Path.cons (Claim.to_expression (Claim.flip claim)) path)
      ]
    )

  let hit_case (dir : int Direction.t) (e : int Formula.t) ~(other_cases : int list) : unit m =
    push_branch_and_tell dir e (fun _ path ->
      let other_dirs =
        match dir with
        | Case_default { not_in } -> List.map not_in ~f:Direction.of_int
        | Case_int i -> Case_default { not_in = i :: other_cases } :: List.map other_cases ~f:Direction.of_int
      in
      List.map other_dirs ~f:(fun d -> 
        Target.make
          (Path.cons (Claim.to_expression (Claim.Equality (e, d))) path)
      )
    )

  let get_input (type a) (make_key : Interp_common.Step.t -> a Input_feeder.Key.t) : Value.t m =
    let%bind () = assert_nondeterminism in
    let%bind s = step in
    let key = make_key s in
    let v = input_feeder.get key in
    match key with
    | I k -> 
      let%bind () = modify (fun s -> { s with rev_inputs = I v :: s.rev_inputs }) in
      return @@ Value.M.VInt (v, Formula.symbol (Formula.Symbol.make_int k)) (* TODO: avoid this conversion, possibly *)
    | B k ->
      let%bind () = modify (fun s -> { s with rev_inputs = B v :: s.rev_inputs }) in
      return @@ Value.M.VBool (v, Formula.symbol (Formula.Symbol.make_bool k))

  let run (x : 'a m) : Status.Eval.t * Target.t list =
    match run x State.empty Read.empty with
    | Ok _, state, Step step ->
      Status.Finished { pruned = Path.length state.path >= max_depth || step > max_step }, state.targets
    | Error e, state, _ -> e, state.targets
end
