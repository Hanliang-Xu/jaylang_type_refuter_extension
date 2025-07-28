open Lexing

exception Parse_error of exn * int * int * string

module type PARSING_DESC = sig
  type token

  val prog : (Lexing.lexbuf -> token) -> Lexing.lexbuf -> Ast.Bluejay.statement list

  val token : Lexing.lexbuf -> token
end

module Make(ParsingDesc : PARSING_DESC) = struct
  let handle_parse_error buf f =
    try f ()
    with exn ->
      let curr = buf.lex_curr_p in
      let line = curr.pos_lnum in
      let column = curr.pos_cnum - curr.pos_bol in
      let tok = lexeme buf in
      raise @@ Parse_error (exn, line, column, tok)

  let parse_program (input : in_channel) =
    let buf = Lexing.from_channel input in
    handle_parse_error buf @@ fun () ->
    ParsingDesc.prog ParsingDesc.token buf

  let parse_single_pgm_string (expr_str : string) = 
    let buf = Lexing.from_string expr_str in
    handle_parse_error buf @@ fun () ->
    ParsingDesc.prog ParsingDesc.token buf

  let parse_file (filename : string) =
    parse_single_pgm_string (Core.In_channel.read_all filename)
end

module Bluejay = Make(
  struct include BluejayParserDesc;; include BluejayLexerDesc;; end
  )

let parse_program_from_file (filename : string) : Ast.some_program =
  match Ast.extension_to_language (Filename.extension filename) with
  | Some language ->
    let channel = Core.In_channel.read_all filename in
    begin
      match language with
      | SomeLanguage BluejayLanguage ->
        SomeProgram (BluejayLanguage, Bluejay.parse_single_pgm_string channel)
      | SomeLanguage DesugaredLanguage ->
        SomeProgram (DesugaredLanguage, failwith "TODO")
      | SomeLanguage EmbeddedLanguage ->
        SomeProgram (EmbeddedLanguage, failwith "TODO")
    end
  | None ->
    raise @@ Invalid_argument (
      Format.sprintf
        "Filename %s provided in argv has unrecognized extension" filename)

let parse_program_from_argv =
  let open Cmdliner.Term.Syntax in
  let+ source_file =
    Cmdliner.Arg.(value & pos 0 (some file) None & info []
                    ~docv:"FILE" ~doc:"Input filename")
  in
  match source_file with 
  | Some filename -> parse_program_from_file filename
  | None -> raise @@ Invalid_argument "No filename provided in argv"
