open Core

open Path_tree

module Node_stack =
  (* sig
    type t
    (** [t] is a nonempty stack of nodes where the bottom of the stack is a root node. *)
    val empty : t
    (** [empty] has an empty root. *)
    val of_root : Root.t -> t
    (** [of_root root] has the formulas of [root] on the bottom of the stack, but the children are discarded *)
    (* val hd_base : t -> Node_base.t *)
    (** [hd_base t] is the top node base in [t]. *)
    (* val map_hd : t -> f:(Node_base.t -> Node_base.t) -> t *)
    (** [map_hd t ~f] maps the head node base of [t] using [f]. *)
    val merge_with_tree : t -> Root.t -> Root.t * Target.t list
    (** [merge_with_tree t root] creates a tree from the stack [t] and merges with the tree given by [root].
        Also returns a new list of targets from nodes in the tree, where the most prioritized target is at the front. *)
    val push : t -> Branch.Runtime.t -> t
    (** [push t branch] pushes the [branch] onto the stack [t] with a copy of all the formulas already on the stack. *)
    val add_formula : t -> Z3.Expr.expr -> t
    (** [add_formula t expr] is [t] where the top node on the stack has gained the formula [expr]. *)
    (* val to_path : t -> Path.t *)
  end
  = *)
  struct
    type t =
      | Last of Root.t
      | Cons of Child.t * t 

    let empty : t = Last Root.empty

    (* To avoid extra children and to keep the stack a single path, begin with only the formulas (and discard the children) from root. *)
    let of_root (root : Root.t) : t =
      Last (Root.with_formulas Root.empty root.formulas)

    let hd_node : t -> Root.t = function
      | Last node -> node
      | Cons (child, _) -> Child.to_node_exn child

    let map_hd (stack : t) ~(f : Node.t -> Node.t) : t =
      match stack with
      | Last base -> Last (f base)
      | Cons (hd, tl) -> Cons (Child.map_node hd ~f, tl) (* might be a good choice to throw exception if node doesn't exist *)

    (* Creates a tree that is effectively the path down the node stack *)
    let to_tree (stack : t) : Root.t =
      let rec to_tree acc = function
        | Last root -> { root with children = acc }
        | Cons ({ status = Hit node ; _} as child, tl) -> (* branch was hit, and no failed assert or assume *)
          let acc = Children.set_node Children.empty child.branch { node with children = acc } in
          to_tree acc tl
        | Cons ({ status = Unsolved ; _} as child, tl) -> (* branch was hit, and failed assert of assume *)
          assert (Children.is_empty acc);
          let acc = Children.set_child Children.empty child in (* has no node in which to set children *)
          to_tree acc tl
        | _ -> failwith "logically impossible" (* impossible if the code does as I expect it *) 
      in
      to_tree Children.empty stack

    (* Gives a root to leaf path by reversing the stack *)
    let to_path (x : t) : Path.t =
      let rec loop acc = function
        | Last _ -> acc
        | Cons (child, tl) -> loop (child.branch :: acc) tl
      in
      loop [] x

    (*
      A target is the other direction of a hit branch. This function returns a list
      of all valid targets found in the stack. The most recently hit branches are at the top
      of the returned stack.
      Assumes the stack has already been merged with the tree.

      I think the total complexity of this has to be quadratic because we need to cut a path short
      in order for it to stop at the target. This isn't great, and maybe its better to keep this
      shorter by storing a reverse path, and we reverse it when we want to trace it.

      Instead, I can probably just store the length of the path needed
    *)
    let get_targets (allowed_tree_depth : int) (stack : t) (tree : Root.t) : Target.t list =
      let total_path = to_path stack in
      let rec step
        (cur_targets : Target.t list)
        (cur_node : Node.t)
        (remaining_path : Path.t)
        (depth : int)
        : Target.t list
        =
        if depth > allowed_tree_depth then cur_targets else
        match remaining_path with
        | last_branch :: [] -> (* maybe last node hit should be target again in case it failed assume or assert *)
          push_target
            (push_target cur_targets cur_node last_branch depth) (* push this direction *)
            cur_node
            (Branch.Runtime.other_direction last_branch) (* push other direction *)
            depth
        | branch :: tl ->
          step
            (push_target cur_targets cur_node (Branch.Runtime.other_direction branch) depth) (* push other direction as possible target *)
            (Child.to_node_exn @@ Node.get_child_exn cur_node branch) (* step down path *)
            tl (* continue down remainder of path *)
            (depth + 1)
        | [] -> cur_targets
      and push_target
        (cur_targets : Target.t list)
        (cur_node : Node.t)
        (branch : Branch.Runtime.t)
        (depth : int)
        : Target.t list
        =
        if Node.is_valid_target_child cur_node branch
        then Target.create (Node.get_child_exn cur_node branch) total_path depth :: cur_targets
        else cur_targets
      in
      step [] tree total_path 0

    (* Note that merging two trees would have to visit every node in both of them in the worst case,
       but we know that the tree made from the stack is a single path, so it only has to merge down
       that single path because only one child is hit and needs to be merged (see Status.merge). *)
    let merge_with_tree (allowed_tree_depth : int) (stack : t) (tree : Root.t) : Root.t * Target.t list =
      let merged =
        Root.merge tree
        @@ to_tree stack
      in
      merged, get_targets allowed_tree_depth stack merged

    let push (stack : t) (branch : Branch.Runtime.t) : t =
      Cons (Child.create Node.empty branch, stack)

    let add_formula (stack : t) (expr : Z3.Expr.expr) : t =
      map_hd stack ~f:(fun node -> Node.add_formula node expr)
  end (* Node_stack *)

(*
  Runtime is a modifier on Path_tracker, so this is a "Runtime Path Tracker".
  The purpose is to separate the variables that can change when the program is
  interpreted from the variables that only change between interpretations.
*)
module Runtime =
  struct
    module Branch_set = Set.Make (Branch)

    module Depth_logic =
      struct
        type t =
          { cur_depth    : int
          ; max_depth    : int
          ; is_below_max : bool } 
          (** [t] helps track if we've reached the max tree depth and thus should stop creating formulas *)

        let empty (max_depth : int) : t =
          { cur_depth = 0; max_depth ; is_below_max = true }

        let incr (x : t) : t =
          { x with cur_depth = x.cur_depth + 1 ; is_below_max = x.cur_depth < x.max_depth }
      end

    type t =
      { stack          : Node_stack.t
      ; target         : Target.t option
      ; has_hit_target : bool
      ; hit_branches   : Branch_set.t
      ; depth          : Depth_logic.t }

    let empty : t =
      { stack          = Node_stack.empty
      ; target         = None
      ; has_hit_target = false
      ; hit_branches   = Branch_set.empty
      ; depth          = Depth_logic.empty Concolic_options.default.max_tree_depth }

    let with_max_depth (x : t) (max_depth : int) : t =
      { x with depth = { x.depth with max_depth } }

    (* [frozen_expr] does not get evaluated unless [x] is below max depth *)
    let add_frozen_formula (x : t) (frozen_expr : unit -> Z3.Expr.expr) : t =
      if x.depth.is_below_max
      then { x with stack = Node_stack.add_formula x.stack @@ frozen_expr () }
      else x

    let hit_branch (x : t) (branch : Branch.Runtime.t) : t =
      (* Format.printf "Hitting branch %s\n" (Branch.Runtime.to_string branch); *)
      let without_formulas =
        { x with
          has_hit_target =
            x.has_hit_target
            || (match x.target with None -> false | Some target -> Branch.Runtime.compare branch target.child.branch = 0)
        ; hit_branches = Set.add x.hit_branches @@ Branch.Runtime.to_ast_branch branch }
      in
      if x.depth.is_below_max
      then
        { without_formulas with
          stack = Node_stack.add_formula (Node_stack.push without_formulas.stack branch) @@ Branch.Runtime.to_expr branch
        ; depth = Depth_logic.incr without_formulas.depth }
      else
        without_formulas

    let fail_assume (x : t) (cx : Lookup_key.t) : t =
      match x.stack with
      | Last _ -> x (* `assume` found in global scope. We assume this is a test case that can't happen in real world translations to JIL *)
      | _ when not x.depth.is_below_max -> x
      | Cons (hd, tl) ->
        let hd = Child.map_node hd ~f:(fun node -> Node.add_formula node @@ Riddler.eqv cx (Jayil.Ast.Value_bool true)) in
        let new_hd =
          Child.{ status = Status.Unsolved (* forget all formulas so that it is a possible target in future runs *)
                ; constraints = Formula_set.add_multi hd.constraints @@ Child.to_formulas hd (* constrain to passing assume/assert *)
                ; branch = hd.branch }
        in
        { x with stack = Cons (new_hd, tl) }

    (*
      ------------------------------
      FORMULAS FOR BASIC JIL CLAUSES
      ------------------------------
    *)
    let add_key_eq_val (x : t) (key : Lookup_key.t) (v : Jayil.Ast.value) : t =
      add_frozen_formula x @@ fun () -> Riddler.eq_term_v key (Some v)

    let add_alias (x : t) (key1 : Lookup_key.t) (key2 : Lookup_key.t) : t =
      add_frozen_formula x @@ fun () -> Riddler.eq key1 key2

    let add_binop (x : t) (key : Lookup_key.t) (op : Jayil.Ast.binary_operator) (left : Lookup_key.t) (right : Lookup_key.t) : t =
      add_frozen_formula x @@ fun () -> Riddler.binop_without_picked key op left right

    let add_input (x : t) (key : Lookup_key.t) (v : Dvalue.t) : t =
      let Ident s = key.x in
      let n =
        match v with
        | Dvalue.Direct (Value_int n) -> n
        | _ -> failwith "non-int input" (* logically impossible *)
      in
      if Printer.print then Format.printf "Feed %d to %s \n" n s;
      add_frozen_formula x @@ fun () -> Riddler.if_pattern key Jayil.Ast.Int_pattern

    let add_not (x : t) (key1 : Lookup_key.t) (key2 : Lookup_key.t) : t =
      add_frozen_formula x @@ fun () -> Riddler.not_ key1 key2

    let add_match (x : t) (k : Lookup_key.t) (m : Lookup_key.t) (pat : Jayil.Ast.pattern) : t =
      add_frozen_formula x
      @@ fun () ->
        let k_expr = Riddler.key_to_var k in
        Solver.SuduZ3.eq (Solver.SuduZ3.project_bool k_expr) (Riddler.if_pattern m pat)

    (*
      -----------------
      BETWEEN-RUN LOGIC   
      -----------------
    *)

    (* Note that other side of all new targets are all the new hits *)
    let finish (x : t) (tree : Root.t) (max_depth : int) : Root.t * Target.t list * Branch.t list =
      if Option.is_some x.target && not x.has_hit_target
      then failwith "missed target branch"; (* logically impossible if the formulas exactly represent the JIL program *)
      let root, targets = Node_stack.merge_with_tree max_depth x.stack tree in
      root, targets, Set.to_list x.hit_branches

    let next (root : Root.t) (target : Target.t) : t =
      { empty with
        stack = Node_stack.of_root root
      ; target = Some target }

    let hd_branch (x : t) : Branch.Runtime.t option =
      match x.stack with
      | Last _ -> None
      | Cons ({ branch ; _}, _) -> Some branch

  end (* Runtime *)

(*
  The user will keep a [t] and use it to enter branches. When the interpretation finishes,
  they will say so, and the stack is traversed to be included in the total tree.   

  This way, we are not modifying the entire path in the tree with every step, and also we 
  don't have to use mutation to avoid it. It just takes one extra pass through the whole thing
  at the end.

  [t] will manage between-run and during-run logic, so the evaluator only has to interface with
  this [t]. The during-run logic is abstracted into Runtime above.
*)
type t =
  { tree          : Root.t (* pointer to the root of the entire tree of paths *)
  ; target_queue  : Target_queue.t
  ; runtime       : Runtime.t
  ; branches      : Branch_tracker.Status_store.Without_payload.t (* quick patch using status store from loose concolic evaluator *)
  ; run_num       : int
  ; options       : Concolic_options.t
  ; quit          : bool }

let empty : t =
  { tree          = Root.empty
  ; target_queue  = Target_queue.empty
  ; runtime       = Runtime.empty
  ; branches      = Branch_tracker.Status_store.Without_payload.empty
  ; run_num       = 0
  ; options       = Concolic_options.default
  ; quit          = false }

let with_options : (t -> t) Concolic_options.F.t =
  Concolic_options.F.make
  @@ fun (r : Concolic_options.t) -> (fun (x : t) -> { x with options = r } : t -> t)

let of_expr (expr : Jayil.Ast.expr) : t =
  { empty with branches = Branch_tracker.Status_store.Without_payload.of_expr expr }

module Formula_logic =
  struct
    (* We delegate the formula logic over to Runtime so that it can selectively compute expressions. *) 
    (* In this module, just call the appropriate runtime function *)

    let add_key_eq_val (x : t) (key : Lookup_key.t) (v : Jayil.Ast.value) : t =
      { x with runtime = Runtime.add_key_eq_val x.runtime key v }

    let add_alias (x : t) (key1 : Lookup_key.t) (key2 : Lookup_key.t) : t =
      { x with runtime = Runtime.add_alias x.runtime key1 key2 }

    let add_binop (x : t) (key : Lookup_key.t) (op : Jayil.Ast.binary_operator) (left : Lookup_key.t) (right : Lookup_key.t) : t =
      { x with runtime = Runtime.add_binop x.runtime key op left right }

    let add_input (x : t) (key : Lookup_key.t) (v : Dvalue.t) : t =
      { x with runtime = Runtime.add_input x.runtime key v }

    let add_not (x : t) (key1 : Lookup_key.t) (key2 : Lookup_key.t) : t =
      { x with runtime = Runtime.add_not x.runtime key1 key2 }

    let add_match (x : t) (k : Lookup_key.t) (m : Lookup_key.t) (pat : Jayil.Ast.pattern) : t =
      { x with runtime = Runtime.add_match x.runtime k m pat }

    let hit_branch (x : t) (branch : Branch.Runtime.t) : t =
      { x with runtime = Runtime.hit_branch x.runtime branch }

    let fail_assume (x : t) (cx : Lookup_key.t) : t =
      { x with runtime = Runtime.fail_assume x.runtime cx }
  end

include Formula_logic

let found_abort (x : t) : t =
  match Runtime.hd_branch x.runtime with
  | None -> failwith "assume in global"
  | Some branch ->
    { x with
      quit = x.options.quit_on_abort
    ; branches =
        Branch_tracker.Status_store.Without_payload.set_branch_status
          x.branches 
          (Branch.Runtime.to_ast_branch branch)
          ~new_status:Found_abort
    }

let reach_max_step (x : t) : t =
  x (* it really doesn't matter that we reach max step. Just conclude like any successful run *)

let next (x : t) : [ `Done of Branch_tracker.Status_store.Without_payload.t | `Next of (t * Session.Eval.t) ] =
  (* first finish *)
  let updated_tree, new_targets, hit_branches = Runtime.finish x.runtime x.tree x.options.max_tree_depth in
  let updated_branches =
    List.fold
      hit_branches
      ~init:x.branches
      ~f:(Branch_tracker.Status_store.Without_payload.set_branch_status ~new_status:Hit)
  in
  let rec next (x : t) : [ `Done of Branch_tracker.Status_store.Without_payload.t | `Next of (t * Session.Eval.t) ] =
    if x.quit then `Done x.branches else
    (* It's never realistically relevant to quit when all branches are hit because at least one will have an abort *)
    (* if Branch_tracker.Status_store.Without_payload.all_hit x.branches then `Done x.branches else *)
    match Target_queue.pop x.target_queue with
    | Some (target, target_queue) -> 
      solve_for_target { x with target_queue } target
    | None when x.run_num = 0 ->
      `Next ({ x with run_num = 1 }, Session.Eval.create Concolic_feeder.default x.options.global_max_step)
    | None -> (* no targets left, so done *)
      `Done x.branches
  and solve_for_target (x : t) (target : Target.t) =
    let t0 = Caml_unix.gettimeofday () in
    let new_solver = Z3.Solver.mk_solver Solver.SuduZ3.ctx None in
    Solver.set_timeout_sec Solver.SuduZ3.ctx (Some (Core.Time_float.Span.of_sec x.options.solver_timeout_sec));
    Z3.Solver.add new_solver (Target.to_formulas target x.tree);
    if x.options.print_solver then
      begin
      Format.printf "Solving for target %s\n" (Branch.Runtime.to_string target.child.branch);
      (* Format.printf "Path is%s\n" (List.to_string target.path ~f:(Branch.Runtime.to_string_short)) *)
      Format.printf "Solver is:\n%s\n" (Z3.Solver.to_string new_solver);
      end;
    match Z3.Solver.check new_solver [] with
    | Z3.Solver.UNSATISFIABLE ->
      let t1 = Caml_unix.gettimeofday () in
      Format.printf "FOUND UNSATISFIABLE in %fs\n" (t1 -. t0); (* TODO: add formula that says it's not satisfiable so less solving is necessary *)
      next { x with tree = Root.set_status x.tree target.child Status.Unsatisfiable target.path }
    | Z3.Solver.UNKNOWN ->
      Format.printf "FOUND UNKNOWN DUE TO SOLVER TIMEOUT\n";
      next { x with tree = Root.set_status x.tree target.child Status.Unknown target.path }
    | Z3.Solver.SATISFIABLE ->
      Format.printf "FOUND SOLUTION FOR BRANCH: %s\n" (Branch.to_string @@ Branch.Runtime.to_ast_branch target.child.branch);
      `Next (
        { x with runtime = Runtime.next x.tree target ; run_num = x.run_num + 1 }
        , Z3.Solver.get_model new_solver
          |> Core.Option.value_exn
          |> Concolic_feeder.from_model
          |> fun feeder -> Session.Eval.create feeder x.options.global_max_step
      )
  in
  { x with tree = updated_tree
  ; target_queue = Target_queue.push_list x.target_queue new_targets
  ; branches = updated_branches
  }
  |> next 


let status_store ({ branches ; _ } : t) : Branch_tracker.Status_store.Without_payload.t =
  branches

let run_num ({ run_num ; _ } : t) : int =
  run_num