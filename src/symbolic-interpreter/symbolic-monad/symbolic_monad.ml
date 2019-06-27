(*
The implementation of this monad includes the following features:

  * Suspension via coroutine
  * Logging via writer (with sanity checking via a "listen"-like mechanism)
  * Nondeterminism via lists
  * State for caching common computations

Note that nondeterminism doesn't play nicely with most other features.  Using
transformers, it is possible to produce nondeterminism *independent* of other
features, but we want the features to interact.  In the event that incoherent
logs are written (e.g. conflicting decisions in function wiring choices), for
example, we want computation to zero.  This requires us to customize the monad
rather than relying on transformer definitions.
*)

open Batteries;;
open Jhupllib;;

open Odefa_ast;;

open Ast;;
open Ast_pp;;
open Interpreter_types;;
(* open Relative_stack;; *)
open Sat_types;;

let lazy_logger =
  Logger_utils.make_lazy_logger "Symbolic_monad"
;;
let _ = lazy_logger;; (* to suppress unused warning *)

type 'a work_info = {
  work_item : 'a;
};;

module type WorkCollection = sig
  type 'a t;;
  val empty : 'a t;;
  val is_empty : 'a t -> bool;;
  val size : 'a t -> int;;
  val offer : 'a work_info -> 'a t -> 'a t;;
  val take : 'a t -> ('a work_info * 'a t) option;;
end;;

module QueueWorkCollection = struct
  type 'a t = 'a work_info Deque.t;;
  let empty = Deque.empty;;
  let is_empty = Deque.is_empty;;
  let size = Deque.size;;
  let offer info dq = Deque.snoc dq info;;
  let take dq = Deque.front dq;;
end;;

module type Cache_key = sig
  include Gmap.KEY;;
  val pp : 'a t Jhupllib.Pp_utils.pretty_printer;;
  val show : 'a t -> string;;
end;;

module type Spec = sig
  module Cache_key : Cache_key;;
  module Work_collection : WorkCollection;;
end;;

module type S = sig
  module Spec : Spec;;

  type 'a m;;

  val return : 'a -> 'a m;;
  val bind : 'a m -> ('a -> 'b m) -> 'b m;;
  val zero : unit -> 'a m;;
  val pick : 'a Enum.t -> 'a m;;
  val pause : unit -> unit m;;
  val cache : 'a Spec.Cache_key.t -> 'a m -> 'a m;;
  val record_decision : Symbol.t -> Ident.t -> clause -> Ident.t -> unit m;;
  val record_formula : Formula.t -> unit m;;
  val check_formulae : 'a m -> 'a m;;

  type 'a evaluation;;

  type 'a evaluation_result =
    { er_value : 'a;
      er_formulae : Formulae.t;
      er_evaluation_steps : int;
      er_result_steps : int;
    };;

  val start : 'a m -> 'a evaluation;;
  val step : 'a evaluation -> 'a evaluation_result Enum.t * 'a evaluation;;
  val is_complete : 'a evaluation -> bool;;
end;;

(** The interface of the functor producing symbolic monads. *)
module Make(Spec : Spec) : S with module Spec = Spec
=
struct
  module Spec = Spec;;
  open Spec;;

  (* **** Supporting types **** *)

  type decision_map =
    (Ident.t * clause * Ident.t) Symbol_map.t
  [@@deriving show]
  ;;
  let _ = show_decision_map;;

  type log = {
    log_formulae : Formulae.t;
    log_decisions : decision_map;
    log_steps : int;
  } [@@deriving show];;
  let _ = show_log;;

  (* Not currently using state. *)
  type state = unit;;

  (* **** Monad types **** *)

  type 'a m = M of (state -> 'a blockable list * state)

  (** An unblocked value is either a completed expression (with its resulting
      state) or a suspended function which, when invoked, will step to the next
      result.  The suspended case carries the log of the computation at the time
      it was suspended. *)
  and 'a unblocked =
    | Completed : 'a * log -> 'a unblocked
    | Suspended : 'a m * log -> 'a unblocked

  (** A blocked value is a function waiting on the completion of a to-be-cached
      computation.  It retains the key of the computation it needs to have
      completed, the function which will use that value to unblock itself, and
      the log at the time computation was suspended.  Since a given computation
      may, via binding, block on many values, the function returns a blockable.
      Note that, although the computation is nondeterministic, each thread of
      computation is serial; there is a fixed order in which blocked values
      require their cached results, so we only wait for one value at a time. *)
  and ('a, 'b) blocked =
    { blocked_key : 'a Cache_key.t;
      blocked_consumer : ('a * log) -> 'b m;
      blocked_computation : 'a m;
    }

  (** A blockable value is either a blocked value or an unblocked value. *)
  and 'a blockable =
    | Blocked : ('z, 'a) blocked -> 'a blockable
    | Unblocked : 'a unblocked -> 'a blockable
  ;;

  (* **** Log utilities **** *)

  let empty_log = {
    log_formulae = Formulae.empty;
    log_decisions = Symbol_map.empty;
    log_steps = 0;
  };;

  exception MergeFailure;;

  let merge_logs (log1 : log) (log2 : log) : log option =
    let open Option.Monad in
    let%bind merged_formulae =
      try
        Some(Formulae.union log1.log_formulae log2.log_formulae)
      with
      | Formulae.SymbolTypeContradiction(_,symbol,types) ->
        (lazy_logger `trace @@ fun () ->
         Printf.sprintf
           "Immediate contradiction at symbol %s with types %s while merging two formula sets.\nSet 1:\n%s\nSet 2:\n%s\n"
           (show_symbol symbol)
           (Jhupllib.Pp_utils.pp_to_string (Jhupllib.Pp_utils.pp_list Formulae.pp_symbol_type) types)
           (Formulae.show log1.log_formulae)
           (Formulae.show log2.log_formulae)
        );
        None
      | Formulae.SymbolValueContradiction(_,symbol,v1,v2) ->
        (lazy_logger `trace @@ fun () ->
         Printf.sprintf
           "Immediate contradiction at symbol %s with values %s and %s while merging two formula sets.\nSet 1:\n%s\nSet 2:\n%s\n"
           (show_symbol symbol)
           (show_value v1) (show_value v2)
           (Formulae.show log1.log_formulae)
           (Formulae.show log2.log_formulae)
        );
        None
    in
    let merge_fn _key a b =
      match a,b with
      | None,None -> None
      | Some x,None -> Some x
      | None,Some x -> Some x
      | Some(x1,c1,x1'),Some(x2,c2,x2') ->
        if equal_ident x1 x2 && equal_ident x1' x2' && equal_clause c1 c2 then
          Some(x1,c1,x1')
        else
          raise MergeFailure
    in
    let%bind merged_decisions =
      try
        Some(Symbol_map.merge merge_fn log1.log_decisions log2.log_decisions)
      with
      | MergeFailure -> None
    in
    let new_log =
      { log_formulae = merged_formulae;
        log_decisions = merged_decisions;
        log_steps = log1.log_steps + log2.log_steps;
      }
    in
    return new_log
  ;;

  (* **** Monadic operations **** *)

  let return (type a) (v : a) : a m =
    M(fun cache -> ([Unblocked(Completed (v, empty_log))], cache))
  ;;

  let zero (type a) () : a m = M(fun state -> ([], state));;

  let _record_log (log : log) : unit m =
    M(fun state -> [Unblocked(Completed((), log))], state)
  ;;

  let bind (type a) (type b) (x : a m) (f : a -> b m) : b m =
    let rec append_log (log : log) (x : b blockable) : b blockable option =
      match x with
      | Unblocked(Completed(value,log')) ->
        begin
          match merge_logs log' log with
          | None -> None
          | Some log'' -> Some(Unblocked(Completed(value,log'')))
        end
      | Unblocked(Suspended(m,log')) ->
        let M(fn) = m in
        let fn' cache =
          let results,cache' = fn cache in
          let results' = List.filter_map (append_log log) results in
          results',cache'
        in
        let m' = M(fn') in
        begin
          match merge_logs log' log with
          | None -> None
          | Some log'' -> Some(Unblocked(Suspended(m',log'')))
        end
      | Blocked(blocked) ->
        let fn' (result,log') =
          match merge_logs log' log with
          | None -> zero ()
          | Some log'' -> blocked.blocked_consumer (result, log'')
        in
        Some(Blocked({blocked with blocked_consumer = fn'}))
    in
    let rec bind_worlds_fn
        (worlds_fn : state -> a blockable list * state) (state : state)
      : b blockable list * state =
      let worlds, state' = worlds_fn state in
      let bound_worlds, state'' =
        worlds
        |> List.fold_left
          (fun (result_worlds, fold_state) world ->
             match world with
             | Unblocked(Completed(value,log)) ->
               let M(fn) = f value in
               let results, fold_cache' = fn fold_state in
               let results' = List.filter_map (append_log log) results in
               (results'::result_worlds, fold_cache')
             | Unblocked(Suspended(m,log)) ->
               let M(fn) = m in
               let m' = M(bind_worlds_fn fn) in
               ([Unblocked(Suspended(m',log))]::result_worlds, fold_state)
             | Blocked(blocked) ->
               let fn' (result,log') =
                 let M(inner_world_fn) =
                   blocked.blocked_consumer (result,log')
                 in
                 (* Here, the monadic value is the result of passing a cached
                    result to the previous caching function.  Once we have
                    that information, we can do the bind against that monadic
                    value. *)
                 M(bind_worlds_fn inner_world_fn)
               in
               let blocked' =
                 { blocked_key = blocked.blocked_key;
                   blocked_consumer = fn';
                   blocked_computation = blocked.blocked_computation;
                 }
               in
               ([Blocked(blocked')]::result_worlds, fold_state)
          )
          ([], state')
      in
      (List.concat bound_worlds, state'')
    in
    let M(worlds_fn) = x in
    M(bind_worlds_fn worlds_fn)
  ;;

  let pick (type a) (items : a Enum.t) : a m =
    M(fun state ->
       (items
        |> Enum.map (fun x -> Unblocked(Completed(x, empty_log)))
        |> List.of_enum
       ),
       state
     )
  ;;

  let pause () : unit m =
    M(fun state ->
       let single_step_log = {empty_log with log_steps = 1} in
       let completed_value = Unblocked(Completed((), single_step_log)) in
       let suspended_value =
         Suspended(M(fun state -> ([completed_value], state)), empty_log)
       in
       ([Unblocked(suspended_value)], state)
     )
  ;;

  let cache (key : 'a Cache_key.t) (value : 'a m) : 'a m =
    M(fun state ->
       let blocked =
         { blocked_key = key;
           blocked_consumer =
             (fun (item,log) ->
                let%bind () = _record_log log in
                return item);
           blocked_computation = value;
         }
       in
       ([Blocked(blocked)], state)
     )
  ;;

  let record_decision (s : Symbol.t) (x : Ident.t) (c : clause) (x' : Ident.t)
    : unit m =
    _record_log @@
    { log_formulae = Formulae.empty;
      log_decisions = Symbol_map.singleton s (x,c,x');
      log_steps = 0;
    }
  ;;

  let record_formula (formula : Formula.t) : unit m =
    _record_log @@
    { log_formulae = Formulae.singleton formula;
      log_decisions = Symbol_map.empty;
      log_steps = 0;
    }
  ;;

  let rec check_formulae : 'a. 'a m -> 'a m =
    fun x ->
      let check_one_world : 'a. 'a blockable -> 'a blockable option =
        fun blockable ->
          match blockable with
          | Unblocked(Completed(_,log)) ->
            if Solver.solvable log.log_formulae then
              Some(blockable)
            else
              None
          | Unblocked(Suspended(m,log)) ->
            Some(Unblocked(Suspended(check_formulae m, log)))
          | Blocked(blocked) ->
            Some(Blocked(
                { blocked with
                  blocked_computation =
                    check_formulae blocked.blocked_computation
                }))
      in
      let M(worlds_fn) = x in
      let fn state =
        let (blockables, state') = worlds_fn state in
        let blockables' = List.filter_map check_one_world blockables in
        (blockables', state')
      in
      M(fn)
  ;;

  (* **** Evaluation types **** *)

  (** A task is a pairing between a monadic value and the destination to which
      its value should be sent upon completion. *)
  type ('out, _) task =
    | Cache_task : 'a Cache_key.t * 'a m -> ('out, 'a) task
    | Result_task : 'out m -> ('out, 'out) task
  ;;

  type 'out some_task = Some_task : ('out, 'a) task -> 'out some_task;;

  (** A sink is a single location into which produced values may be consumed.
      When a value is consumed, it produces a computation together with the
      destination of that computation's work. *)
  type ('out, 'a) consumer =
    | Consumer : ('a * log -> 'out some_task) -> ('out, 'a) consumer
  ;;

  (** A destination contains information about how completed values are to be
      consumed.  A destination of type t consumes values of type t.  A
      destination also retains its previously-dispatched values; new consumers
      can (and should) be provided these values immediately upon
      registration. *)
  type ('out, 'a) destination =
    { dest_consumers : ('out, 'a) consumer list;
      dest_values : ('a * log) list;
    }
  ;;

  (* **** BEGIN GADT NIGHTMARE CODE **** *)
  (* So we have a problem.  The Gmap module creates polymorphic dictionaries
     based on GADT keys (yay!) but quite reasonably demands that the keys have
     only a single type parameter (boo anyway!).  As a result, our destination
     key isn't suitable.  This is a problem, since the destination key *needs*
     the 'out parameter to ensure that the consumers produce the right kind of
     Result_task values.  To solve this, we're going to
        1. Wrap the result of a Gmap.Make inside of another module.
        2. Provide the minimal subset of functionality required here in the
           wrapper.
        3. Bundle the module as a first-class value along with the dictionary
           it manipulates.
     This effectively embeds the 'out parameter as a fixture of the module, so
     the wrapper module can define its own key type to provide to Gmap and then
     translate back and forth as necessary.  Oh, the things I do for types!
  *)

  module type Type = sig
    type t;;
  end;;

  module type Destination_map_sig = sig
    type out;;
    type t;;
    type 'a value = (out, 'a) destination;;
    val empty : t;;
    val add : 'a Cache_key.t -> 'a value -> t -> t;;
    val find : 'a Cache_key.t  -> t -> 'a value option;;
  end;;

  module Make_destination_map(Out : Type)
    : Destination_map_sig with type out = Out.t =
  struct
    type out = Out.t;;
    type 'a value = (out, 'a) destination;;
    module Key = struct
      type 'a t = K : 'a Cache_key.t -> (out, 'a) destination t;;
      let compare : type a b. a t -> b t -> (a, b) Gmap.Order.t = fun k k' ->
        match k, k' with
        | K(ck), K(ck') ->
          begin
            match Cache_key.compare ck ck' with
            | Lt -> Lt
            | Eq -> Eq
            | Gt -> Gt
          end
      ;;
    end;;
    module M = Gmap.Make(Key);;
    type t = M.t;;
    let _push
        (type a)
        (k : a Cache_key.t)
      : (out, a) destination Key.t =
      Key.K(k)
    ;;
    (* let _pull (k : 'a Key.t) : (out, 'a) destination_key =
       let Key.K(cache_key) = k in Destination_key cache_key
       ;; *)
    let empty : M.t = M.empty;;
    let add (type a) (k : a Cache_key.t) (v : a value) (m : M.t) : M.t =
      M.add (_push k) v m
    ;;
    let find (type a) (k : a Cache_key.t) (m : M.t) =
      M.find (_push k) m
    ;;
  end;;

  type 'out destination_map =
      Destination_map :
        ((module Destination_map_sig with type out = 'out and type t = 't) * 't)
        -> 'out destination_map
  ;;

  (* **** END GADT NIGHTMARE CODE **** *)

  (**
     An evaluation is a monadic value for which evaluation has started.  It is
     representative of all of the concurrent, non-deterministic computations
     being performed as well as all metadata (such as caching).
  *)
  type 'out evaluation =
    { ev_state : state;
      ev_tasks : 'out some_task Work_collection.t;
      ev_destinations : 'out destination_map;
      ev_evaluation_steps : int;
    }
  ;;

  type 'out evaluation_result =
    { er_value : 'out;
      er_formulae : Formulae.t;
      er_evaluation_steps : int;
      er_result_steps : int;
    };;

  (* **** Evaluation operations **** *)

  type 'a some_blocked = Some_blocked : ('z,'a) blocked -> 'a some_blocked;;

  let _step_m (state : state) (x : 'a m) :
    ('a * log) Enum.t *     (* Completed results *)
    'a m list *             (* Suspended computations *)
    'a some_blocked list *  (* Blocking computations *)
    state                   (* Resulting state *)
    =
    let M(world_fn) = x in
    let (worlds, state') = world_fn state in
    let (complete,suspended,blocked) =
      worlds
      |> List.fold_left
        (fun (complete,suspended,blocked) world ->
           match world with
           | Unblocked(Completed(value,log)) ->
             ((value,log)::complete,suspended,blocked)
           | Unblocked(Suspended(m,_)) ->
             (complete,m::suspended,blocked)
           | Blocked(x) ->
             (complete,suspended,(Some_blocked(x))::blocked)
        )
        ([],[],[])
    in
    (List.enum complete, suspended, blocked, state')
  ;;

  (** Adds a task to an evaluation's queue. *)
  let _add_task
      (type out) (task : out some_task) (ev : out evaluation)
    : out evaluation =
    let item = { work_item = task; } in
    { ev with ev_tasks = Work_collection.offer item ev.ev_tasks }
  ;;

  (** Adds many tasks to an evaluation's queue. *)
  let _add_tasks
      (type out) (tasks : out some_task Enum.t) (ev : out evaluation)
    : out evaluation =
    Enum.fold (flip _add_task) ev tasks
  ;;

  (** Processes the production of a value at a cache destination.  This adds the
      value to the destination and calls any consumers listening to it. *)
  let _produce_at
      (type a) (type out)
      (key : a Cache_key.t)
      (value : a)
      (log : log)
      (ev : out evaluation)
    : out evaluation =
    let Destination_map(dm,destination_map) = ev.ev_destinations in
    let (module Destination_map) = dm in
    match Destination_map.find key destination_map with
    | None ->
      (* This should never happen:
         1. _produce_at is only called when a cache task produces a value
         2. A cache task can only produce a value if it has been started
         3. Cache tasks are only started by blocked computations
         4. Blocked computations create a destination for their keys
      *)
      raise @@ Utils.Invariant_failure
        "Destination not established by the time it was produced!"
    | Some destination ->
      (* Start by adding the new value. *)
      let destination' =
        { destination with
          dest_values = (value, log) :: destination.dest_values;
        }
      in
      let destination_map' =
        Destination_map.add key destination' destination_map
      in
      let dm' = Destination_map(dm, destination_map') in
      let ev' = { ev with ev_destinations = dm' } in
      (* Now create the tasks from the consumers. *)
      let new_tasks =
        destination.dest_consumers
        |> List.enum
        |> Enum.map
          (fun consumer ->
             let Consumer fn = consumer in
             fn (value, log)
          )
      in
      (* Add the tasks to the evaluation environment. *)
      _add_tasks new_tasks ev'
  ;;

  (** Registers a consumer to a cache destination.  This adds the consumer to
      the destination and processes the "catch-up" of the consumer on all
      previously produced values. *)
  let _register_consumer
      (type a) (type out)
      (key : a Cache_key.t)
      (consumer : (out, a) consumer)
      (ev : out evaluation)
    : out evaluation =
    let Destination_map(dm,destination_map) = ev.ev_destinations in
    let (module Destination_map) = dm in
    match Destination_map.find key destination_map with
    | None ->
      (* This should never happen:
         1. _register_consumer is only called when a blocked computation is
            discovered
         2. That code immediately adds a destination to the evaluation
            environment under this key
      *)
      raise @@ Utils.Invariant_failure
        "Destination not established by the time it was produced!"
    | Some destination ->
      (* Start by registering the consumer. *)
      let destination' =
        { destination with
          dest_consumers = consumer :: destination.dest_consumers;
        }
      in
      let destination_map' =
        Destination_map.add key destination' destination_map
      in
      let dm' = Destination_map(dm, destination_map') in
      let ev' = { ev with ev_destinations = dm' } in
      (* Now catch the consumer up on all of the previous values. *)
      let Consumer fn = consumer in
      let new_tasks =
        destination.dest_values
        |> List.enum
        |> Enum.map fn
      in
      (* Add the new tasks to the evaluation environment *)
      _add_tasks new_tasks ev'
  ;;

  let start (type out) (x : out m) : out evaluation =
    let initial_state = () in
    let module Destination_map =
      Make_destination_map(struct type t = out end)
    in
    let destination_map =
      Destination_map((module Destination_map), Destination_map.empty)
    in
    let empty_evaluation =
      { ev_state = initial_state;
        ev_tasks = Work_collection.empty;
        ev_destinations = destination_map;
        ev_evaluation_steps = 0;
      }
    in
    _add_task (Some_task(Result_task x)) empty_evaluation
  ;;

  let step (type a) (ev : a evaluation)
    : (a evaluation_result Enum.t * a evaluation) =
    match Work_collection.take ev.ev_tasks with
    | None ->
      (* There is no work left to do.  Don't step. *)
      (Enum.empty(), ev)
    | Some({work_item = task}, tasks') ->
      (* The overall strategy of the algorithm below is:
            1. Get a task and do the work
            2. If the task is for a cached result, dispatch any new values to
               the registered consumers.
            3. If the task is for a final result, communicate any new values to
               the caller.
            4. Add all suspended computations as future tasks.
            5. Add all blocked computations as consumers.
         Because of how type variables are scoped, however, steps 1, 2, and 3
         must be within the respective match branches which destructed the task
         values.  We'll push what we can into local functions to limit code
         duplication.
      *)
      lazy_logger `trace (fun () ->
          let task_descr =
            match task with
            | Some_task(Cache_task(key, _)) ->
              "cache key " ^ Cache_key.show key
            | Some_task(Result_task _) ->
              "result"
          in
          "Stepping task for " ^ task_descr
        );
      let handle_computation
          (type t)
          (mk_task : t m -> a some_task)
          (computation : t m) (ev' : a evaluation)
        : ((t * log) Enum.t * a evaluation) =
        (* Do the work that is asked. *)
        let (complete, suspended, blocked, state') =
          _step_m ev.ev_state computation
        in
        (* Update our evaluation to reflect the state change and the step. *)
        let ev_after_step =
          { ev_state = state';
            ev_tasks = tasks';
            ev_destinations = ev'.ev_destinations;
            ev_evaluation_steps = ev'.ev_evaluation_steps + 1;
          }
        in
        (* From the completed task, any suspended computations get added to the
           task list with the same destination. *)
        let ev_after_processing_suspended =
          suspended
          |> List.enum
          |> Enum.map mk_task
          |> flip _add_tasks ev_after_step
        in
        (* From the completed task, all blocked computations should be added as
           consumers of the cache key on which they are blocking.  If the cache
           key has not been seen previously, then its computation should be
           started. *)
        let ev_after_processing_blocked =
          blocked
          |> List.enum
          |> Enum.fold
            (fun (ev : a evaluation) some_blocked ->
               let Destination_map(dm,destination_map) = ev.ev_destinations in
               let (module Destination_map) = dm in
               let Some_blocked(blocked) = some_blocked in
               (* Ensure that the destination for this computation exists. *)
               let key = blocked.blocked_key in
               let computation = blocked.blocked_computation in
               let ev' : a evaluation =
                 match Destination_map.find key destination_map with
                 | None ->
                   (* We've never heard of this destination before.  That means
                      this is the first cache request on this key, so we should
                      create it and then start computing for it. *)
                   let dest = { dest_consumers = []; dest_values = []; } in
                   let task = Some_task(Cache_task(key, computation)) in
                   let destination_map' =
                     destination_map
                     |> Destination_map.add key dest
                   in
                   let ev' =
                     { ev with
                       ev_destinations = Destination_map(dm,destination_map');
                     }
                   in
                   let (ev'' : a evaluation) = _add_task task ev' in
                   ev''
                 | Some _ ->
                   (* This destination already exists.  We don't need to do
                      anything to make it ready for the consumer to be
                      registered. *)
                   ev
               in
               (* Create the new consumer from the blocked evaluation.  Once it
                  receives a value, the blocked evaluation will produce a new
                  computation intended for the same destination, just as with a
                  suspended computation. *)
               let consumer = Consumer(
                   fun (value,log) ->
                     let computation = blocked.blocked_consumer (value, log) in
                     mk_task computation
                 )
               in
               let ev'' = _register_consumer key consumer ev' in
               ev''
            )
            ev_after_processing_suspended
        in
        (complete, ev_after_processing_blocked)
      in
      let ((completed : (a * log) Enum.t), ev') =
        match task with
        | Some_task(Cache_task(key, computation)) ->
          (* Do computation and update state. *)
          let (complete, ev_after_computation) =
            handle_computation
              (fun computation -> Some_task(Cache_task(key, computation)))
              computation ev
          in
          (* Every value in the completed sequence should be reported to the
             destination specified by this key. *)
          let ev_after_completed =
            complete
            |> Enum.fold
              (fun ev'' (value, log) -> _produce_at key value log ev'')
              ev_after_computation
          in
          (Enum.empty(), ev_after_completed)
        | Some_task(Result_task(computation)) ->
          (* Do computation and update state. *)
          let (complete, ev_after_computation) =
            handle_computation
              (fun computation -> Some_task(Result_task(computation)))
              computation ev
          in
          (* Every value in the completed sequence should be returned to the
             caller. *)
          (complete, ev_after_computation)
      in
      (* Alias for clarity *)
      let final_ev = ev' in
      (* Process the output to make it presentable to the caller. *)
      let output : a evaluation_result Enum.t =
        completed
        |> Enum.map
          (fun (value, log) ->
             { er_value = value;
               er_formulae = log.log_formulae;
               er_evaluation_steps = final_ev.ev_evaluation_steps;
               er_result_steps = log.log_steps + 1;
               (* The +1 here is to ensure that the number of steps reported is
                  equal to the number of times the "step" function has been
                  called.  For a given result, the "step" function must be
                  called once for each "pause" (which is handled inductively
                  when the "pause" monadic function modifies the log) plus once
                  because the "start" routine implicitly pauses computation.
                  This +1 addresses what the "start" routine does. *)
             }
          )
      in
      (output, final_ev)
  ;;

  let is_complete (ev : 'a evaluation) : bool =
    Work_collection.is_empty ev.ev_tasks
  ;;
end;;
