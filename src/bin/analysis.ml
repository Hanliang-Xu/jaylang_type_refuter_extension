(**
  Bin [analysis].

  This executable runs the program analysis on a Bluejay
  program at the given file path.
*)

open Cmdliner
open Cmdliner.Term.Syntax

let analyze =
  Cmd.v (Cmd.info "analyze") @@
  let+ pgm = Lang.Parse.parse_bjy_file_from_argv 
  and+ `Do_wrap do_wrap, `Do_type_splay do_type_splay = Translate.Convert.cmd_arg_term in
  Translate.Convert.bjy_to_emb pgm ~do_wrap ~do_type_splay
  |> Lang.Ast_tools.Utils.pgm_to_module
  |> Lang.Ast.Embedded.With_callsites.alphatized_of_expr
  |> Analysis.Main.analyze
  |> Analysis.Grammar.M.run_for_error
  |> function
    | Ok _value_set -> Format.printf "Your program is error-free\n"
    | Error err -> Format.printf "ERROR: the analysis found an error.\n%s\n" (Analysis.Grammar.Err.to_string err)

let () = 
  exit @@ Cmd.eval analyze
