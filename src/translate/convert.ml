
open Lang
open Ast

let cmd_arg_term =
  let open Cmdliner.Term.Syntax in
  let open Cmdliner.Arg in
  let+ do_wrap = value & opt (enum ["yes", true ; "no", false]) true & info ["w"] ~doc:"Wrap flag: yes or no. Default is yes."
  and+ splay = value & flag & info ["s"] ~doc:"Splay types on recursive functions"
  and+ depth = value & opt int 3 & info ["y"] ~doc:"Depth to generate recursive types if type-splaying is on. Default is 3." in
  (`Do_wrap do_wrap, `Do_type_splay (if splay then Splay.Yes_with_depth depth else No))

let cmd_arg_term_with_check_index =
  let open Cmdliner.Term.Syntax in
  let open Cmdliner.Arg in
  let+ do_wrap = value & opt (enum ["yes", true ; "no", false]) true & info ["w"] ~doc:"Wrap flag: yes or no. Default is yes."
  and+ splay = value & flag & info ["s"] ~doc:"Splay types on recursive functions"
  and+ depth = value & opt int 3 & info ["y"] ~doc:"Depth to generate recursive types if type-splaying is on. Default is 3."
  and+ check_index = value & opt (some int) None & info ["check-index"] ~doc:"Index of check to enable" in
  (`Do_wrap do_wrap, `Do_type_splay (if splay then Splay.Yes_with_depth depth else No), `Check_index check_index)

let filter_checks_to_index_desugared (des : Desugared.pgm) ~(check_index : int option) : Desugared.pgm =
  let turn_off = Ast.Desugared.turn_off_check in

  match check_index with
  | None -> des
  | Some target_idx ->
    let has_check (stmt : Desugared.statement) : bool =
      match stmt with
      | SUntyped _ -> false
      | STyped { typed_binding_opts = TBDesugared { do_check ; _ } ; _ } ->
        do_check
    in
    let rec go check_idx prev_stmts stmts =
      match stmts with
      | [] -> prev_stmts
      | stmt :: tl ->
        if has_check stmt && check_idx = target_idx
        then
          (* Keep this check on *)
          go (check_idx + 1) (prev_stmts @ [ stmt ]) tl
        else if has_check stmt
        then
          (* Turn off all other checks *)
          go (check_idx + 1) (prev_stmts @ [ turn_off stmt ]) tl
        else
          (* No check in this statement, keep as is *)
          go check_idx (prev_stmts @ [ stmt ]) tl
    in
    go 0 [] des

let des_to_emb (des : Desugared.pgm) ~(do_wrap : bool) ~(do_type_splay : Splay.t) ~(check_index : int option) : Embedded.pgm =
  let module Names = Translation_tools.Fresh_names.Make () in
  des
  |> filter_checks_to_index_desugared ~check_index
  |> Embed.embed_pgm (module Names) ~do_wrap ~do_type_splay

let des_to_many_emb (des : Desugared.pgm) ~(do_wrap : bool) ~(do_type_splay : Splay.t) ~(check_index : int option) : Embedded.pgm Preface.Nonempty_list.t =
  ignore check_index;
  let module Names = Translation_tools.Fresh_names.Make () in
  des |> Embed.embed_fragmented (module Names) ~do_wrap ~do_type_splay

let bjy_to_des (bjy : Bluejay.pgm) ~(do_type_splay : Splay.t) : Desugared.pgm =
  let module Names = Translation_tools.Fresh_names.Make () in
  Desugar.desugar_pgm (module Names) bjy ~do_type_splay

let bjy_to_emb (bjy : Bluejay.pgm) ~(do_wrap : bool) ~(do_type_splay : Splay.t) ~(check_index : int option) : Embedded.pgm =
  let module Names = Translation_tools.Fresh_names.Make () in
  let des_pgm = 
    match check_index with
    | None -> Desugar.desugar_pgm (module Names) bjy ~do_type_splay
    | Some _ -> Desugar.filter_checks_to_index_before_desugar (module Names) bjy ~do_type_splay ~check_index
  in
  Embed.embed_pgm (module Names) des_pgm ~do_wrap ~do_type_splay

let bjy_to_many_emb (bjy : Bluejay.pgm) ~(do_wrap : bool) ~(do_type_splay : Splay.t) ~(check_index : int option) : Embedded.pgm Preface.Nonempty_list.t =
  let module Names = Translation_tools.Fresh_names.Make () in
  bjy
  |> bjy_to_des ~do_type_splay
  |> des_to_many_emb ~do_wrap ~do_type_splay ~check_index

let bjy_to_many_emb_split_first (bjy : Bluejay.pgm) ~(do_wrap : bool) ~(do_type_splay : Splay.t) ~(check_index : int option) : Embedded.pgm Preface.Nonempty_list.t =
  let module Names = Translation_tools.Fresh_names.Make () in
  let des_pgm = Desugar.split_checks_before_desugar (module Names) bjy ~do_type_splay ~check_index in
  Preface.Nonempty_list.Last (Embed.embed_pgm (module Names) des_pgm ~do_wrap ~do_type_splay)

let bjy_to_erased (bjy : Bluejay.pgm) : Type_erased.pgm =
  Type_erasure.erase bjy

let some_program_to_emb (prog : some_program) ~(do_wrap : bool) ~(do_type_splay : Splay.t) ~(check_index : int option) : Embedded.pgm =
  match prog with
  | SomeProgram(BluejayLanguage, bjy_prog) ->
    bjy_to_emb ~do_wrap ~do_type_splay ~check_index bjy_prog
  | SomeProgram(DesugaredLanguage, des_prog) ->
    des_to_emb ~do_wrap ~do_type_splay ~check_index des_prog
  | SomeProgram(EmbeddedLanguage, emb_prog) ->
    emb_prog

let some_program_to_many_emb (prog : some_program) ~(do_wrap : bool) ~(do_type_splay : Splay.t) : Embedded.pgm Preface.Nonempty_list.t =
  match prog with
  | SomeProgram(BluejayLanguage, bjy_prog) ->
    bjy_to_many_emb ~do_wrap ~do_type_splay ~check_index:None bjy_prog
  | SomeProgram(DesugaredLanguage, des_prog) ->
    des_to_many_emb ~do_wrap ~do_type_splay ~check_index:None des_prog
  | SomeProgram(EmbeddedLanguage, emb_prog) ->
    Last emb_prog