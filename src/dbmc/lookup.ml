open Core
open Dj_common
open Jayil
open Jayil.Ast
open Cfg
open Log.Export
module U_ddse = Lookup_ddse_rule.U

let[@landmark] run_ddse ~(config : Global_config.t) ~(state : Global_state.t) :
    unit Lwt.t =
  (* reset and init *)
  Solver.reset () ;
  Riddler.reset () ;

  let unroll = U_ddse.create () in
  let term_target = Lookup_key.start state.target in

  let module LS = (val (module struct
                         let state = state
                         let config = config

                         let add_phi key phi phis =
                           let term_detail =
                             Hashtbl.find_exn state.term_detail_map key
                           in
                           term_detail.phis <- phi :: term_detail.phis ;
                           Set.add phis phi

                         let block_map = state.block_map
                         let unroll = unroll
                       end) : Lookup_ddse_rule.S)
  in
  let module R = Lookup_ddse_rule.Make (LS) in
  (* block works similar to env in a common interpreter *)
  let[@landmark] rec run_task key block phis =
    match Hashtbl.find state.term_detail_map key with
    | Some _ -> ()
    | None ->
        let term_detail : Term_detail.t =
          let block_id = Cfg.id_of_block block in
          let x, _r_stk = Lookup_key.to2 key in
          let rule = Rule.rule_of_runtime_status x block in
          Term_detail.mk_detail ~rule ~block ~key
        in
        Hashtbl.add_exn state.term_detail_map ~key ~data:term_detail ;
        let task () =
          Scheduler.push state.job_queue key (lookup key block phis)
        in
        U_ddse.alloc_task unroll ~task key
  and lookup (this_key : Lookup_key.t) block phis () : unit Lwt.t =
    let x, _r_stk = Lookup_key.to2 this_key in

    (* let this_node = Global_state.find_node_exn state this_key in *)
    let block_id = Cfg.id_of_block block in

    (* match Riddler.check_phis (Set.to_list phis) false with
       | None -> Lwt.return_unit
       | Some _ -> *)
    let rule = Rule.rule_of_runtime_status x block in
    LLog.app (fun m ->
        m "[Lookup][=>]: %a in block %a; Rule %a" Lookup_key.pp this_key Id.pp
          block_id Rule.pp_rule rule) ;

    let _apply_rule =
      let open Rule in
      match rule with
      | Discovery_main p -> R.discovery_main p this_key phis
      | Discovery_nonmain p ->
          R.discovery_nonmain p this_key block phis run_task
      | Input p -> R.input p this_key block phis run_task
      | Alias p -> R.alias p this_key block phis run_task
      | Not b -> R.not_ b this_key block phis run_task
      | Binop b -> R.binop b this_key block phis run_task
      | Record_start p -> R.record_start p this_key block phis run_task
      | Cond_top cb -> R.cond_top cb this_key block phis run_task
      | Cond_btm p -> R.cond_btm p this_key block phis run_task
      | Fun_enter_local p -> R.fun_enter_local p this_key phis run_task
      | Fun_enter_nonlocal p -> R.fun_enter_nonlocal p this_key phis run_task
      | Fun_exit p -> R.fun_exit p this_key block phis run_task
      | Pattern p -> R.pattern p this_key block phis run_task
      | Assume p -> R.assume p this_key block phis run_task
      | Assert p -> R.assert_ p this_key block phis run_task
      | Abort p -> R.abort p this_key block phis run_task
      | Mismatch -> R.mismatch this_key phis
    in

    (* LLog.app (fun m ->
        m "[Lookup][<=]: %a in block %a" Lookup_key.pp this_key Id.pp block_id) ; *)
    Lwt.return_unit
  in

  (* let _ = Global_state.init_node state term_target state.root_node in *)
  let block0 = Cfg.block_of_id state.target state.block_map in
  let phis = Phi_set.empty in
  run_task term_target block0 phis ;

  let wait_result =
    U_ddse.by_iter unroll term_target (fun (r : Ddse_result.t) ->
        let phis_to_check = Set.to_list r.phis in
        match Checker.check_phis phis_to_check config.debug_model with
        | None -> Lwt.return_unit
        | Some { model; c_stk } ->
            raise (Riddler.Found_solution { model; c_stk }))
  in

  let%lwt _ =
    Lwt.pick
      [
        (let%lwt _ = Scheduler.run state.job_queue in
         Lwt.return_unit);
        wait_result;
      ]
  in
  Lwt.return_unit

let[@landmark] run_dbmc ~(config : Global_config.t) ~(state : Global_state.t) :
    unit Lwt.t =
  (* reset and init *)
  Solver.reset () ;
  Riddler.reset () ;
  state.phis <- [ Riddler.picked (Lookup_key.start state.target) ] ;

  let add_phi (term_detail : Term_detail.t) phi =
    term_detail.phis <- phi :: term_detail.phis ;
    state.phis <- phi :: state.phis
  in
  let stride = ref config.stride_init in

  let unroll = Lookup_rule.U.create () in

  let run_eval key block eval =
    match Hashtbl.find state.term_detail_map key with
    | Some _ -> ()
    | None ->
        if Hash_set.mem state.lookup_created key
        then ()
        else (
          Hash_set.strict_add_exn state.lookup_created key ;
          let task () = Scheduler.push state.job_queue key (eval key block) in
          Lookup_rule.U.alloc_task unroll ~task key)
  in

  let module LS = (val (module struct
                         let state = state
                         let config = config
                         let block_map = state.block_map
                       end) : Lookup_rule.S)
  in
  let module R = Lookup_rule.Make (LS) in
  let[@landmark] rec lookup (key : Lookup_key.t) block () : unit Lwt.t =
    let x, _r_stk = Lookup_key.to2 key in

    let rule = Rule.rule_of_runtime_status x block in

    let block_id = Cfg.id_of_block block in
    let term_detail = Term_detail.mk_detail ~rule ~block ~key in

    Hashtbl.add_exn state.term_detail_map ~key ~data:term_detail ;
    state.tree_size <- state.tree_size + 1 ;

    Checker.step_check ~state ~config stride ;%lwt

    Hash_set.strict_remove_exn state.lookup_created key ;

    LLog.app (fun m ->
        m "[Lookup][%d][=>]: %a in block %a; Rule %a" state.tree_size
          Lookup_key.pp key Id.pp block_id Rule.pp_rule rule) ;

    let edge =
      let open Rule in
      match rule with
      | Discovery_main p -> R.discovery_main p key
      | Discovery_nonmain p -> R.discovery_nonmain p key block
      | Input p -> R.input p key block
      | Alias p -> R.alias p key block
      | Not p -> R.not_ p key block
      | Binop b -> R.binop b key block
      | Record_start p -> R.record_start p key block
      | Cond_top cb -> R.cond_top cb key block
      | Cond_btm p -> R.cond_btm p key block
      | Fun_enter_local p -> R.fun_enter_local p key block
      | Fun_enter_nonlocal p -> R.fun_enter_nonlocal p key block
      | Fun_exit p -> R.fun_exit p key block
      | Pattern p -> R.pattern p key block
      | Assume p -> R.assume p key
      | Assert p -> R.assert_ p key
      | Abort p -> R.abort p key block
      | Mismatch -> R.mismatch key
    in
    let run_task key block = run_eval key block lookup in
    Run_rule_action.run run_task unroll state term_detail edge ;

    (* Fix for SATO. `abort` is a side-effect clause so it needs to be implied picked.
        run all previous lookups *)
    let previous_clauses = Cfg.clauses_before_x block x in
    List.iter previous_clauses ~f:(fun tc ->
        let term_prev = Lookup_key.with_x key tc.id in
        add_phi term_detail (Riddler.picked_imply key term_prev) ;
        run_task term_prev block) ;

    LLog.app (fun m ->
        m "[Lookup][<=]: %a in block %a" Lookup_key.pp key Id.pp block_id) ;

    Lwt.return_unit
  in

  let key_target = Lookup_key.start state.target in
  (* let _ = Global_state.init_node state key_target state.root_node in *)
  let block0 = Cfg.block_of_id state.target state.block_map in
  run_eval key_target block0 lookup ;
  let%lwt _ = Scheduler.run state.job_queue in
  Lwt.return_unit
