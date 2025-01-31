
open Lang
open Ast

let[@landmark] bjy_to_emb (bjy : Bluejay.t) ~(do_wrap : bool) : Embedded.t =
  let module Names = Translation_tools.Fresh_names.Make () in
  bjy
  |> Desugar.desugar_bluejay (module Names)
  |> Embed.embed_desugared (module Names) ~do_wrap

let[@landmark] bjy_to_des (bjy : Bluejay.t) : Desugared.t =
  let module Names = Translation_tools.Fresh_names.Make () in
  Desugar.desugar_bluejay (module Names) bjy
