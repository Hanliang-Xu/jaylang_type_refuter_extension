open Core
open Odefa_ast
open Odefa_ast.Ast
open Tracelet
open Log.Export

type result_info = Riddler.result_info

exception Found_solution of result_info

module U = Global_state.Unroll

let[@landmark] run ~(config : Global_config.t) ~(state : Global_state.t)
    job_queue : unit =
  let target = state.target in
  let map = state.block_map in
  let x_first = state.first in
  (* let block0 = Tracelet.cut_before true target block in *)
  let block0 = Tracelet.find_by_id target map in

  let add_phi = Global_state.add_phi state in

  let find_or_add_node key block node_parent =
    Global_state.find_or_add_node state key block node_parent |> snd
  in

  (* reset and init *)
  Solver.reset () ;
  Riddler.reset () ;
  state.phis_z3 <- [ Riddler.pick_at_key (Lookup_key.start target) ] ;

  (* async handler *)
  (Lwt.async_exception_hook :=
     fun exn ->
       match exn with
       | Found_solution _ -> raise exn
       | _ -> failwith "unknown exception") ;

  let module RS = (val (module struct
                         let state = state
                         let add_phi = add_phi
                         let x_first = x_first
                       end) : Ruler.Ruler_state)
  in
  let module R = Ruler.Make (RS) in
  (* block works similar to env in a common interpreter *)
  let[@landmark] rec run_task key block =
    let task () = Scheduler.push job_queue key (lookup key block) in
    U.alloc_task state.unroll ~task key
  and lookup (this_key : Lookup_key.t) block () : unit Lwt.t =
    let x, xs, r_stk = Lookup_key.to_parts this_key in
    let gate_tree = Global_state.find_node_exn state this_key block in

    (* update global state *)
    state.tree_size <- state.tree_size + 1 ;
    Hash_set.strict_remove_exn state.lookup_created this_key ;

    (* LLog.app (fun m ->
       m "[Lookup][=>]: %a in block %a" Lookup_key.pp this_key Id.pp
         (Tracelet.id_of_block block)) ; *)
    let p = Riddler.pick_at_key this_key in
    let rule = Rule.rule_of_runtime_status x xs block in
    let apply_rule () =
      let open Rule in
      match rule with
      | Discovery_main (DM { v; _ })
      | Discovery_nonmain (DN { v; _ })
      | Discard (D { v; _ })
      | Record_end (RE { v; _ }) ->
          R.deal_with_value state (Some v) this_key block gate_tree run_task
            find_or_add_node
      | Input (I _) ->
          LLog.debug (fun m -> m "Rule Value (Input)") ;
          Hash_set.add state.input_nodes this_key ;
          R.deal_with_value state None this_key block gate_tree run_task
            find_or_add_node
      | Alias (A { x; x' }) ->
          LLog.debug (fun m -> m "Rule Alias: %a" Ast_pp.pp_ident x') ;
          let key_rx = Lookup_key.replace_x this_key x' in
          let node_rx = find_or_add_node key_rx block gate_tree in
          Node.update_rule gate_tree (Node.alias node_rx) ;
          add_phi this_key (Riddler.alias this_key x') ;

          run_task key_rx block ;
          U.by_id state.unroll this_key key_rx ;%lwt

          Lookup_result.ok_lwt x
      | Record_start (RS { x; r; lbl }) ->
          LLog.info (fun m ->
              m "Rule ProjectBody : %a = %a.%a" Id.pp x Id.pp r Id.pp lbl) ;
          let key_r = Lookup_key.replace_x this_key x in
          let node_r = find_or_add_node key_r block gate_tree in
          let key_r_l = Lookup_key.replace_x2 this_key (r, lbl) in
          let node_r_l = find_or_add_node key_r_l block gate_tree in

          Node.update_rule gate_tree (Node.project node_r node_r_l) ;
          add_phi this_key (Riddler.alias_key this_key key_r_l) ;

          run_task key_r_l block ;
          U.by_id state.unroll this_key key_r_l ;%lwt

          Lookup_result.ok_lwt x
      | Binop (B { x; bop; x1; x2 }) ->
          let key_x1 = Lookup_key.of_parts x1 xs r_stk in
          let node_x1 = find_or_add_node key_x1 block gate_tree in
          let key_x2 = Lookup_key.of_parts x2 xs r_stk in
          let node_x2 = find_or_add_node key_x2 block gate_tree in

          Node.update_rule gate_tree (Node.binop node_x1 node_x2) ;
          add_phi this_key (Riddler.binop this_key bop x1 x2) ;

          run_task key_x1 block ;
          run_task key_x2 block ;
          U.by_map2 state.unroll this_key key_x1 key_x2 (fun _ ->
              Lookup_result.ok x) ;
          Lookup_result.ok_lwt x
      | Cond_top (CT cb) ->
          let condsite_block = Tracelet.outer_block block map in
          let choice = Option.value_exn cb.choice in
          let condsite_stack =
            match Rstack.pop r_stk (cb.point, Id.cond_fid choice) with
            | Some stk -> stk
            | None -> failwith "impossible in CondTop"
          in
          let x2 = cb.cond in

          let key_x2 = Lookup_key.of_parts x2 [] condsite_stack in
          let node_x2 = find_or_add_node key_x2 condsite_block gate_tree in
          let key_xxs = Lookup_key.of_parts x xs condsite_stack in
          let node_xxs = find_or_add_node key_xxs condsite_block gate_tree in

          Node.update_rule gate_tree (Node.cond_choice node_x2 node_xxs) ;
          add_phi this_key (Riddler.cond_top this_key cb condsite_stack) ;

          run_task key_x2 condsite_block ;

          let cb this_key (rc : Lookup_result.t) =
            let c = rc.from in
            if true
            then (
              run_task key_xxs condsite_block ;
              Lwt.async (fun () -> U.by_id state.unroll this_key key_xxs))
            else () ;
            Lwt.return_unit
          in
          U.by_bind state.unroll this_key key_x2 cb ;%lwt

          Lookup_result.ok_lwt x
      | Cond_btm (CB { x; x'; tid }) ->
          let cond_block =
            Ident_map.find tid map |> Tracelet.cast_to_cond_block
          in
          if Option.is_some cond_block.choice
          then failwith "conditional_body: not both"
          else () ;
          let key_cond_var = Lookup_key.of_parts x' [] r_stk in
          let cond_var_tree = find_or_add_node key_cond_var block gate_tree in

          let sub_trees =
            List.fold [ true; false ]
              ~f:(fun sub_trees beta ->
                let ctracelet, key_x_ret =
                  Lookup_key.get_cond_block_and_return cond_block beta r_stk x
                    xs
                in
                let node_x_ret =
                  find_or_add_node key_x_ret ctracelet gate_tree
                in
                sub_trees @ [ node_x_ret ])
              ~init:[]
          in

          Hash_set.strict_add_exn state.lookup_created this_key ;
          Node.update_rule gate_tree
            (Node.mk_condsite ~cond_var_tree ~sub_trees) ;

          let remove_once =
            lazy
              (Hash_set.strict_remove_exn state.lookup_created this_key ;
               add_phi this_key (Riddler.cond_bottom this_key cond_block x'))
          in
          let remove_mutex = Nano_mutex.create () in

          run_task key_cond_var block ;

          let cb this_key (c : Lookup_result.t) =
            if c.status
            then (
              Nano_mutex.critical_section remove_mutex ~f:(fun () ->
                  ignore @@ Lazy.force remove_once) ;

              List.iter [ true; false ] ~f:(fun beta ->
                  if Riddler.eager_check state config key_cond_var
                       [ Riddler.bind_x_v [ x' ] r_stk (Value_bool beta) ]
                  then (
                    let ctracelet, key_x_ret =
                      Lookup_key.get_cond_block_and_return cond_block beta r_stk
                        x xs
                    in

                    run_task key_x_ret ctracelet ;
                    Lwt.async (fun () ->
                        U.by_id state.unroll this_key key_x_ret))
                  else ()) ;
              Lwt.return_unit)
            else Lwt.return_unit
          in
          U.by_bind state.unroll this_key key_cond_var cb ;%lwt
          Lookup_result.ok_lwt x
      | Fun_enter_local (FEL { x; fb; is_local })
      | Fun_enter_nonlocal (FEN { x; fb; is_local }) ->
          let fid = fb.point in
          let callsites =
            match Rstack.paired_callsite r_stk fid with
            | Some callsite -> [ callsite ]
            | None -> fb.callsites
          in
          LLog.debug (fun m ->
              m "FunEnter%s: %a -> %a"
                (if is_local then "" else "Nonlocal")
                Id.pp fid Id.pp_list callsites) ;
          let sub_trees, lookups =
            List.fold callsites
              ~f:(fun (sub_trees, lookups) callsite ->
                let callsite_block, x', x'', x''' =
                  Tracelet.fun_info_of_callsite callsite map
                in
                match Rstack.pop r_stk (x', fid) with
                | Some callsite_stack ->
                    let key_f = Lookup_key.of_parts x'' [] callsite_stack in
                    let node_f =
                      find_or_add_node key_f callsite_block gate_tree
                    in
                    let _lookup_f = run_task key_f callsite_block in
                    let key_arg =
                      if is_local
                      then Lookup_key.of_parts x''' xs callsite_stack
                      else Lookup_key.of_parts x'' (x :: xs) callsite_stack
                    in
                    let node_arg =
                      find_or_add_node key_arg callsite_block gate_tree
                    in
                    let _lookup_f_arg = run_task key_arg callsite_block in
                    (sub_trees @ [ (node_f, node_arg) ], lookups @ [ key_arg ])
                | None -> (sub_trees, lookups))
              ~init:([], [])
          in

          Node.update_rule gate_tree (Node.mk_para ~sub_trees) ;
          add_phi this_key
            (Riddler.fun_enter this_key is_local fb callsites map) ;

          U.by_join state.unroll this_key lookups ;%lwt
          Lookup_result.ok_lwt x
      | Fun_exit (FE { x; xf; fids }) ->
          LLog.debug (fun m -> m "FunExit: %a -> %a" Id.pp xf Id.pp_list fids) ;
          let key_fun = Lookup_key.of_parts xf [] r_stk in
          let node_fun = find_or_add_node key_fun block gate_tree in
          let sub_trees =
            List.fold fids
              ~f:(fun sub_trees fid ->
                let fblock = Ident_map.find fid map in
                let key_x_ret = Lookup_key.get_f_return map fid r_stk x xs in
                let node_x_ret = find_or_add_node key_x_ret fblock gate_tree in
                sub_trees @ [ node_x_ret ])
              ~init:[]
          in

          Node.update_rule gate_tree
            (Node.mk_callsite ~fun_tree:node_fun ~sub_trees) ;
          add_phi this_key (Riddler.fun_exit this_key xf fids map) ;

          run_task key_fun block ;

          let cb this_key (rf : Lookup_result.t) =
            let fid = rf.from in
            if List.mem fids fid ~equal:Id.equal
            then (
              let fblock = Ident_map.find fid map in
              let key_x_ret = Lookup_key.get_f_return map fid r_stk x xs in

              run_task key_x_ret fblock ;
              Lwt.async (fun () -> U.by_id state.unroll this_key key_x_ret) ;
              Lwt.return_unit)
            else Lwt.return_unit
          in

          U.by_bind state.unroll this_key key_fun cb ;%lwt
          Lookup_result.ok_lwt x
      | Mismatch ->
          Node.update_rule gate_tree Node.mismatch ;
          add_phi this_key (Riddler.mismatch this_key) ;
          Lookup_result.fail_lwt x
    in
    let%lwt _rule_result = apply_rule () in
    let%lwt _ =
      if state.tree_size mod config.steps = 0
      then (
        LLog.app (fun m ->
            m "Step %d\t%a\n" state.tree_size Lookup_key.pp this_key) ;
        match Riddler.check state config with
        | Some { model; c_stk } -> Lwt.fail (Found_solution { model; c_stk })
        | None -> Lwt.return_unit)
      else Lwt.return_unit
    in
    LLog.debug (fun m ->
        m "[Lookup][<=]: %a in block %a\n" Lookup_key.pp this_key Id.pp
          (Tracelet.id_of_block block)) ;
    Lwt.return_unit
  in

  let key_target = Lookup_key.of_parts target [] Rstack.empty in
  let _ = Global_state.init_node state key_target state.root_node in
  run_task key_target block0