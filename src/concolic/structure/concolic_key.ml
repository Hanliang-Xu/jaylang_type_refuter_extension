
(* module T =
  struct
    type t =
      { x : Jayil.Ast.Ident_new.t
      ; n : Fun_depth.t } (* n is number of functions entered in path to variable *)
      [@@deriving hash, compare, equal, sexp]
  end

include T

let create (x : Jayil.Ast.ident) (fun_depth : Fun_depth.t) : t =
  { x ; n = fun_depth }

let to_string ({ x ; n } : t) : string = 
  Format.sprintf "%s_$%s$" (Dj_common.Id.show x) (Fun_depth.to_string n)

let x ({ x ; _ } : t) : Jayil.Ast.ident =
  x

let n ({ n ; _ } : t) : Fun_depth.t =
  n
*)

open Core

type t =
  { id : Jayil.Ast.Ident_new.t
  ; x  : int }
  [@@deriving hash, compare, equal, sexp]

let create (id : Jayil.Ast.Ident_new.t) (x : int) : t =
  { id ; x }

let to_string ({ id = Ident s ; x } : t) : string =
  Format.sprintf "%s_$%d" s x

let id ({ id ; _ } : t) : Jayil.Ast.Ident_new.t =
  id

let x ({ x ; _ } : t) : int =
  x