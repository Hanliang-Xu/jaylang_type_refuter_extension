open! Core

let read_source ?(is_instrumented = false) filename =
  let program =
    if Jay.File_utils.check_ext filename
    then
      (* failwith "TBI!" *)
      let natast =
        In_channel.with_file filename ~f:Jay.Jay_parse.parse_program_raw
      in
      let nat_edesc = Jay.Jay_ast.new_expr_desc natast in
      (* let on_expr, ton_on_maps =
           Jay.Jay_to_jayil.translate (Jay.Jay_ast.new_expr_desc natast)
         in *)
      Jay.Jay_to_jayil.translate ~is_instrumented nat_edesc |> fun (e, _, _) ->
      e
    else if Jayil.File_utils.check_ext filename
    then
      let ast =
        In_channel.with_file filename ~f:Jayil_parser.Parse.parse_program_raw
      in
      if is_instrumented
      then Jay_instrumentation.Instrumentation.instrument_jayil ast |> fst
      else ast
    else failwith "file extension must be .jay or .jil"
  in
  ignore @@ Global_config.check_wellformed_or_exit program ;
  program