open Core
open Lwt.Infix
open Odefa_ast
open Odefa_ast.Ast
open Tracelet
open Odefa_ddpa
open Log.Export

let handle_graph (config : Global_config.t) state model =
  if config.debug_graph
  then Graphviz.output_graph ~model ~testname:config.filename state
  else ()

let handle_found (config : Global_config.t) (state : Global_state.t) model c_stk
    =
  LLog.info (fun m ->
      m "{target}\nx: %a\ntgt_stk: %a\n\n" Ast.pp_ident config.target
        Concrete_stack.pp c_stk) ;
  (* LLog.debug (fun m ->
      m "Nodes picked states\n%a\n"
        (Fmt.Dump.iter_bindings
           (fun f c ->
             Hashtbl.iteri c ~f:(fun ~key ~data:_ ->
                 f key (Riddler.is_picked (Some model) key)))
           Fmt.nop Lookup_key.pp Fmt.bool)
        state.node_map) ; *)
  Hashtbl.clear state.rstk_picked ;
  Hashtbl.iter_keys state.node_map ~f:(fun key ->
      if Riddler.is_picked (Some model) key
      then ignore @@ Hashtbl.add state.rstk_picked ~key:key.r_stk ~data:true
      else ()) ;
  (* Global_state.refresh_picked state model; *)
  handle_graph config state (Some model) ;

  let inputs_from_interpreter = Solver.get_inputs ~state ~config model c_stk in
  [ inputs_from_interpreter ]

let[@landmark] main_with_state_lwt ~(config : Global_config.t)
    ~(state : Global_state.t) =
  let job_queue =
    let open Scheduler in
    let cmp t1 t2 =
      Int.compare (Lookup_key.length t1.key) (Lookup_key.length t2.key)
    in
    Scheduler.create ~cmp ()
  in
  let post_check_dbmc () =
    match Riddler.check state config with
    | Some { model; c_stk } -> handle_found config state model c_stk
    | None ->
        SLog.info (fun m -> m "UNSAT") ;
        if config.debug_model
        then
          SLog.debug (fun m -> m "Solver Phis: %s" (Solver.string_of_solver ()))
        else () ;
        handle_graph config state None ;
        []
  in
  let post_check_ddse () =
    if config.debug_model
    then SLog.debug (fun m -> m "Solver Phis: %s" (Solver.string_of_solver ()))
    else () ;
    handle_graph config state None ;
    []
  in
  try%lwt
    (Lwt.async_exception_hook :=
       fun exn ->
         match exn with
         | Riddler.Found_solution { model; c_stk } ->
             LLog.app (fun m -> m "async_exception_hook") ;
             ignore @@ raise (Riddler.Found_solution { model; c_stk })
         | exn -> failwith (Caml.Printexc.to_string exn)) ;
    let do_work () =
      match config.engine with
      | Global_config.E_dbmc ->
          Lookup.run_dbmc ~config ~state job_queue >>= fun _ ->
          Lwt.return (post_check_dbmc ())
      | Global_config.E_ddse ->
          Lookup.run_ddse ~config ~state job_queue >>= fun _ ->
          Lwt.return (post_check_ddse ())
    in
    match config.timeout with
    | Some ts -> Lwt_unix.with_timeout (Time.Span.to_sec ts) do_work
    | None -> do_work ()
  with
  | Riddler.Found_solution { model; c_stk } ->
      LLog.app (fun m -> m "handle found?") ;
      Lwt.return (handle_found config state model c_stk)
  | Lwt_unix.Timeout ->
      prerr_endline "timeout" ;
      Lwt.return (post_check_ddse ())

let main_lwt ~config program =
  let state = Global_state.create config program in
  main_with_state_lwt ~config ~state

let main ~config program = Lwt_main.run @@ main_lwt ~config program

let main_commandline () =
  let cfg = Argparse.parse_commandline_config () in
  Log.init cfg ;
  let program = File_util.read_source cfg.filename in
  (try
     let inputss = main ~config:cfg program in

     match List.hd inputss with
     | Some inputs ->
         Format.printf "[%s]\n"
           (String.concat ~sep:","
           @@ List.map
                ~f:(function Some i -> string_of_int i | None -> "-")
                inputs)
     | None -> Format.printf "Unreachable"
   with ex -> (* Printexc.print_backtrace Out_channel.stderr ; *)
              raise ex) ;

  Log.close ()
(* ignore @@ raise GenComplete *)
