open! Core

let read_source ?(is_instrumented = false) filename =
  let program =
    if Jay.File_utils.check_ext filename
    then
      (* failwith "TBI!" *)
      let natast =
        In_channel.with_file filename ~f:Jay.On_parse.parse_program_raw
      in
      let nat_edesc = Jay.On_ast.new_expr_desc natast in
      (* let on_expr, ton_on_maps =
           Jay.On_to_odefa.translate (Jay.On_ast.new_expr_desc natast)
         in *)
      Jay.On_to_odefa.translate ~is_instrumented nat_edesc |> fun (e, _, _) -> e
    else if Jayil.File_utils.check_ext filename
    then
      let ast =
        In_channel.with_file filename ~f:Jayil_parser.Parse.parse_program_raw
      in
      if is_instrumented
      then Jay_instrumentation.Instrumentation.instrument_odefa ast |> fst
      else ast
    else failwith "file extension must be .odefa or .natodefa"
  in
  ignore @@ Global_config.check_wellformed_or_exit program ;
  program

(*
let parse_natodefa = Jay.On_parse.parse_string
let parse_odefa = Jayil_parser.Parser.parse_string
let read_lines file = file |> In_channel.create |> In_channel.input_lines

let read_src file =
  file |> read_lines |> List.map ~f:String.strip
  |> List.filter ~f:(fun line -> not String.(prefix line 1 = "#"))
  |> String.concat ~sep:"\n"
*)

(*
let src_text = read_src testname in
let src =
  if Dbmc.File_util.is_natodefa_ext testname
  then parse_natodefa src_text
  else parse_odefa src_text
     in *)