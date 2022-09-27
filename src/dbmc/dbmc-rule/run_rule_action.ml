open Core
open Dj_common
module U = Unrolls.U_dbmc

let init_list_counter (state : Global_state.t) (term_detail : Term_detail.t) key
    =
  Hashtbl.update state.smt_lists key ~f:(function
    | Some i -> i
    | None ->
        Global_state.add_phi state term_detail (Riddler.list_head key) ;
        0)

let fetch_list_counter (state : Global_state.t) (term_detail : Term_detail.t)
    key =
  let new_i =
    Hashtbl.update_and_return state.smt_lists key ~f:(function
      | Some i -> i + 1
      | None ->
          failwith (Fmt.str "why not inited : %a" Lookup_key.pp key)
          (* add_phi state term_detail (Riddler.list_head key) ;
             1 *))
  in
  new_i - 1

let add_phi_edge state term_detail edge =
  let open Rule_action in
  let phis =
    match edge with
    | Withered e -> e.phis
    | Leaf e -> e.phis
    | Direct e -> e.phis
    | Map e -> e.phis
    | MapSeq e -> e.phis
    | Both e -> e.phis
    | Chain e -> e.phis
    | Sequence e -> e.phis
    | Or_list e -> e.phis
  in
  List.iter phis ~f:(Global_state.add_phi state term_detail)

let rec run run_task unroll (state : Global_state.t)
    (term_detail : Term_detail.t) rule_action =
  let loop rule_action = run run_task unroll state term_detail @@ rule_action in
  let add_phi = Global_state.add_phi state in
  let open Rule_action in
  add_phi_edge state term_detail rule_action ;
  match (rule_action : Rule_action.t) with
  | Withered e -> ()
  | Leaf e -> U.by_return unroll e.sub (Lookup_result.ok e.sub)
  | Direct e ->
      run_task e.pub ;
      U.by_id_u unroll e.sub e.pub
  | Map e ->
      run_task e.pub ;
      U.by_map_u unroll e.sub e.pub e.map
  | MapSeq e ->
      init_list_counter state term_detail e.sub ;
      run_task e.pub ;
      let f r =
        let i = fetch_list_counter state term_detail e.sub in
        let ans, phis = e.map i r in
        add_phi term_detail (Riddler.list_append e.sub i (Riddler.and_ phis)) ;
        ans
      in
      U.by_map_u unroll e.sub e.pub f
  | Both e ->
      run_task e.pub1 ;
      run_task e.pub2 ;
      U.by_map2_u unroll e.sub e.pub1 e.pub2 (fun _ -> Lookup_result.ok e.sub)
  | Chain e ->
      let cb key r =
        let edge = e.next key r in
        (match edge with Some edge -> loop edge | None -> ()) ;
        Lwt.return_unit
      in
      U.by_bind_u unroll e.sub e.pub cb ;
      run_task e.pub
  | Sequence e ->
      init_list_counter state term_detail e.sub ;

      run_task e.pub ;
      let cb _key (r : Lookup_result.t) =
        let i = fetch_list_counter state term_detail e.sub in
        let next = e.next i r in
        (match next with
        | Some (phi_i, next) ->
            let phi = Riddler.list_append e.sub i phi_i in
            add_phi term_detail phi ;
            loop next
        | None ->
            add_phi term_detail (Riddler.list_append e.sub i Riddler.false_)) ;
        Lwt.return_unit
      in
      U.by_bind_u unroll e.sub e.pub cb
  | Or_list e ->
      if e.unbound then init_list_counter state term_detail e.sub else () ;
      List.iter e.nexts ~f:(fun e -> loop e)