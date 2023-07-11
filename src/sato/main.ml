open Core
open Jayil.Ast
open Jay_translate.Jay_to_jayil_maps
open Sato_result

let main_lwt ~config program_full : (reported_error option * bool) Lwt.t =
  let program = Dj_common.Convert.jil_ast_of_convert program_full in
  let dbmc_config_init = Sato_args.sato_to_dbmc_config config in
  Dj_common.Log.init dbmc_config_init ;
  let init_sato_state =
    Sato_state.initialize_state_with_expr config.sato_mode program_full
  in
  let target_vars = init_sato_state.target_vars in
  Fmt.pr "[SATO] #tgt=%d@.@?" (List.length target_vars) ;
  let rec search_all_targets (remaining_targets : ident list)
      (has_timeout : bool) : (reported_error option * bool) Lwt.t =
    match remaining_targets with
    | [] -> Lwt.return (None, has_timeout)
    | hd :: tl -> (
        let dbmc_config = { dbmc_config_init with target = hd } in
        (* Right now we're stopping after one error is found. *)
        try
          let open Dbmc in
          Fmt.pr "[SATO] #tgt=%a  #s=%a@.@?" Ident.pp hd
            (Fmt.option Time_float.Span.pp)
            dbmc_config.timeout ;
          let%lwt { inputss; state = dbmc_state; is_timeout; _ } =
            Dbmc.Main.main_lwt ~config:dbmc_config program
          in
          match List.hd inputss with
          | Some inputs -> (
              let () = print_endline "Lookup target: " in
              let () = print_endline @@ Dj_common.Id.show hd in
              let session =
                {
                  (Interpreter.make_default_session ()) with
                  input_feeder = Input_feeder.from_list inputs;
                }
              in
              try Interpreter.eval session program
              with Interpreter.Found_abort ab_clo -> (
                match ab_clo with
                | AbortClosure final_env ->
                    let result =
                      match config.sato_mode with
                      | Bluejay ->
                          let errors =
                            Sato_result.Bluejay_type_errors.get_errors
                              init_sato_state dbmc_state session final_env
                              inputs
                          in
                          (Some (Bluejay_error errors), has_timeout)
                      | Jay ->
                          let errors =
                            Sato_result.Jay_type_errors.get_errors
                              init_sato_state dbmc_state session final_env
                              inputs
                          in
                          (Some (Jay_error errors), has_timeout)
                      | Jayil ->
                          let errors =
                            Sato_result.Jayil_type_errors.get_errors
                              init_sato_state dbmc_state session final_env
                              inputs
                          in
                          (Some (Jayil_error errors), has_timeout)
                    in
                    Lwt.return result
                | _ -> failwith "Shoud have run into abort here!"))
          | None ->
              if is_timeout
              then search_all_targets tl true
              else search_all_targets tl has_timeout
        with ex -> (* Printexc.print_backtrace Out_channel.stderr ; *)
                   raise ex)
  in
  search_all_targets target_vars false

let main ~config program_full = Lwt_main.run (main_lwt ~config program_full)

let do_output_parsable program filename output_parsable =
  if output_parsable
  then
    let purged_expr = Jayil.Ast_tools.purge program in
    let og_file = Filename.chop_extension (Filename.basename filename) in
    let new_file = og_file ^ "_instrumented.jil" in
    Dj_common.File_utils.dump_to_file purged_expr new_file

let main_commandline () =
  let sato_config = Argparse.parse_commandline_config () in
  let program_full =
    Dj_common.File_utils.read_source_full ~do_wrap:sato_config.do_wrap
      ~do_instrument:sato_config.do_instrument sato_config.filename
  in
  do_output_parsable
    (Dj_common.Convert.jil_ast_of_convert program_full)
    sato_config.filename sato_config.output_parsable ;
  let () =
    let errors_res = main ~config:sato_config program_full in
    match errors_res with
    | None, false -> print_endline @@ "No errors found."
    | None, true ->
        print_endline
        @@ "Some search timed out; inconclusive result. Please run again with \
            longer timeout setting."
    | Some errors, _ -> print_endline @@ show_reported_error errors
  in
  Dj_common.Log.close ()
