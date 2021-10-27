open Core

module T = struct
  type t = {
    key : Lookup_key.t;
    block_id : Id.t;
    rule : (rule[@ignore]);
    mutable preds : (edge list[@ignore]);
    mutable has_complete_path : bool;
    mutable all_path_searched : bool;
  }

  and edge = { pred : t ref; succ : t ref }

  and rule =
    (* special rule *)
    | Pending
    (* value rule *)
    | Done of Concrete_stack.t
    | Mismatch
    | Discard of t ref
    | Alias of t ref
    | To_first of t ref
    | Binop of t ref * t ref
    | Cond_choice of t ref * t ref
    | Condsite of t ref * t ref list
    | Callsite of t ref * t ref list
    | Para_local of (t ref * t ref) list
    | Para_nonlocal of (t ref * t ref) list
  [@@deriving sexp, compare, equal, show { with_path = false }]

  let rule_name = function
    | Pending -> "Pending"
    | Done _ -> "Done"
    | Mismatch -> "Mismatch"
    | Discard _ -> "Discard"
    | Alias _ -> "Alias"
    | To_first _ -> "To_first"
    | Binop _ -> "Binop"
    | Cond_choice _ -> "Cond_choice"
    | Callsite _ -> "Callsite"
    | Condsite _ -> "Condsite"
    | Para_local _ -> "Para_local"
    | Para_nonlocal _ -> "Para_nonlocal"

  let pp_rule_name oc rule = Fmt.pf oc "%s" (rule_name rule)
end

module Node = struct
  include T
  include Comparator.Make (T)
end

module Node_ref = struct
  module T = struct
    type t = Node.t ref
    [@@deriving sexp, compare, equal, show { with_path = false }]

    let hash = Hashtbl.hash
  end

  include T
  include Comparator.Make (T)
end

open Node

let mk_edge pred succ = { pred; succ }

let root_node block_id x =
  {
    block_id;
    key = Lookup_key.start x;
    rule = Pending;
    preds = [];
    has_complete_path = false;
    all_path_searched = false;
  }

let mk_node ~block_id ~key ~rule =
  {
    block_id;
    key;
    rule;
    preds = [];
    has_complete_path = false;
    all_path_searched = false;
  }

let add_pred node pred =
  if
    List.mem !node.preds pred ~equal:(fun eg1 eg2 ->
        phys_equal eg1.pred eg2.pred)
  then
    () (* failwith "why duplicate cvars on edge" *)
  else
    !node.preds <- pred :: !node.preds

let mk_callsite ~fun_tree ~sub_trees = Callsite (fun_tree, sub_trees)

let mk_condsite ~cond_var_tree ~sub_trees = Condsite (cond_var_tree, sub_trees)

let mk_para ~sub_trees = Para_local sub_trees

let pending_node = Pending

let done_ cstk = Done cstk

let discard node = Discard node

let mismatch = Mismatch

let alias node = Alias node

let to_first node = To_first node

let binop n1 n2 = Binop (n1, n2)

let cond_choice nc nr = Cond_choice (nc, nr)

(*
   cvars is actually some real or virtual out-edges of a node.
   In node-based-recursive function, it's OK to set the cvar for
   the node associated with that edge
*)

let traverse_node ?(stop = fun _ -> false) ~at_node ~init ~acc_f node =
  let visited = Hash_set.create (module Lookup_key) in
  let rec loop ~acc node =
    let is_stop = stop node in
    if is_stop then
      ()
    else (* visit this node *)
      let duplicate =
        match Hash_set.strict_add visited !node.key with
        | Ok () ->
            at_node node;
            false
        | Error _ -> true
      in
      let acc = acc_f acc node in
      (* traverse its children *)
      if not duplicate then
        match !node.rule with
        | Pending | Done _ | Mismatch -> ()
        | Discard child | Alias child | To_first child -> loop ~acc child
        | Binop (n1, n2) | Cond_choice (n1, n2) ->
            List.iter ~f:(loop ~acc) [ n1; n2 ]
        | Callsite (node, child_edges) | Condsite (node, child_edges) ->
            loop ~acc node;
            List.iter ~f:(fun n -> loop ~acc n) child_edges
        | Para_local ncs | Para_nonlocal ncs ->
            List.iter
              ~f:(fun (n1, n2) -> List.iter ~f:(loop ~acc) [ n1; n2 ])
              ncs
      else
        ()
  in
  loop ~acc:init node

let fold_tree ?(stop = fun _ -> false) ~init ~sum node =
  let rec loop ~acc node =
    let is_stop = stop node in
    if is_stop then
      ()
    else (* fold this node *)
      let acc = sum acc node in
      (* fold its children *)
      match !node.rule with
      | Pending | Done _ | Mismatch -> acc
      | Discard child | Alias child | To_first child -> loop ~acc child
      | Binop (n1, n2) | Cond_choice (n1, n2) ->
          List.fold ~init:acc ~f:sum [ n1; n2 ]
      | Callsite (node, child_edges) | Condsite (node, child_edges) ->
          let acc = sum acc node in
          List.fold ~init:acc ~f:(fun acc n -> sum acc n) child_edges
      | Para_local ncs | Para_nonlocal ncs ->
          List.fold ~init:acc ~f:(fun acc (n1, n2) -> sum (sum acc n1) n2) ncs
  in
  loop ~acc:init node
