open Core

module Pop_kind =
  struct
    type t =
      | DFS
      | BFS
      | Prioritize_uncovered
      | Random

    let random () =
      match Random.int 3 with
      | 0 -> DFS
      | 1 -> BFS
      | _ -> Prioritize_uncovered
  end

module Q = Psq.Make (Target) (Int) (* functional priority search queue *)

module Priority =
  struct
    type t = Front | Back 
  end

module T =
  struct
    type t =
      { m    : int (* maximum (i.e. least prioritized) priority in the queue. *)
      ; q    : Q.t
      ; prio : Priority.t }
      (* Note: we will not update m if the item associated with m is pushed to the front because
          we only want some priority that is guaranteed to be the worst, and m still is in that case. *)

    (* default priority for only element in queue *)
    let default_prio = 0

    let empty (prio : Priority.t): t = 
      { m = default_prio + 1 (* note that max priority is actually the *least prioritized* item. Lower prio is better. *)
      ; q = Q.empty
      ; prio }

    let push_one ({ q ; m ; prio } as x : t) (target : Target.t) : t =
      match prio with
      | Front -> begin
        match Q.min q with (* O(1) access of most prioritized *) 
        | None -> { x with q = Q.push target default_prio q } (* queue was empty *)
        | Some (_, best_prio) -> { x with q = Q.push target (best_prio - 1) q }  (* push target with best priority *)
      end
      | Back -> begin
        (* use `push` so that if it is already in the queue, it is not moved to the back. To move to the back, use `add`. *)
        { x with q = Q.push target m q ; m = m + 1 }
      end

    (*
      Notes:    
      * If priority is Front, then the first targets in ls get worse priority
      * If priority is Back, then the first targets in ls get better priority
    *)
    let push_list (x : t) (ls : Target.t list) : t =
      List.fold
        ls
        ~init:x
        ~f:push_one

    let pop ({ q ; _ } as x : t) : (Target.t * t) option =
      match Q.pop q with
      | None -> None
      | Some ((target, _), q) -> Some (target, { x with q })

    let remove ({ q ; _ } as x : t) (target : Target.t) : t =
      { x with q = Q.remove target q }
  end

type t =
  { dfs : T.t
  ; bfs : T.t
  ; hit : Q.t } (* prioritized by number of times the target has been hit *)
  
let empty : t =
  { dfs = T.empty Front
  ; bfs = T.empty Back
  ; hit = Q.empty }

(* Deeper targets are at the front of [ls] *)
let push_list ({ dfs ; bfs ; hit } : t) (ls : Target.t list) (hits : int list) : t =
  { dfs = T.push_list dfs (List.rev ls) (* reverse so that deeper targets have better priority *)
  ; bfs = T.push_list bfs ls
  ; hit = List.fold2_exn ls hits ~init:hit ~f:(fun acc k p -> Q.push k p acc) }

let remove (x : t) (target : Target.t) : t =
  { bfs = T.remove x.bfs target
  ; dfs = T.remove x.dfs target
  ; hit = Q.remove target x.hit }

let rec pop ?(kind : Pop_kind.t = DFS) (x : t) : (Target.t * t) option =
  match kind with
  | DFS -> begin
    match T.pop x.dfs with
    | Some (target, dfs) -> Some (target, remove { x with dfs } target)
    | None -> None
  end
  | BFS -> begin
    match T.pop x.bfs with
    | Some (target, bfs) -> Some (target, remove { x with bfs } target)
    | None -> None
  end
  | Prioritize_uncovered -> begin
    match Q.pop x.hit with
    | Some ((target, _), hit) -> Some (target, remove { x with hit } target)
    | None -> None
  end
  | Random -> pop ~kind:(Pop_kind.random ()) x


(*
  TODO: want to add a queue where the targets have priority by the number of times they have been hit in the AST.
  * So basically whenever a target is pushed, we give it priority equal to the number of times any instance of
    that branch has been hit.
  * We don't want to only store that in the target queue because if no instance of the target is in the queue,
    then what priority do we give it? We must store it elsewhere.
  * Disregarding finding failed assumes, we can say hitting a line is the same as hitting the branch encompassing it.
  * Need to be careful about not doubling up on the counts for hitting a failed assume, then hitting the branch correctly
    immediately afterwards.
*)