let () =
  let open Cmdliner in
  let file_arg = Arg.(required & pos 0 (some file) None & info [] ~docv:"FILE" ~doc:"Input .bjy file") in
  let cmd = Cmd.v (Cmd.info "json_parser") (Term.(const (fun filename ->
    let content = Core.In_channel.read_all filename in
    let json_output = Lang.Parser.parse_program_to_json content in
    print_string json_output
  ) $ file_arg)) in
  match Cmd.eval_value' cmd with
  | `Ok _ -> ()
  | `Exit i -> exit i