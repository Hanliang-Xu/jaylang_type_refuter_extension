open Core

module T = struct
  type t = Z3.Expr.expr

  let sexp_of_t e = Sexp.Atom (Z3.Expr.to_string e)
  let compare = Z3.Expr.compare
  (* let equal_expr e1 e2 = Z3.Expr.compare e1 e2 = 0 *)
end

module S = struct
  include T
  include Comparator.Make (T)
end

include S

type set = Set.M(S).t

let empty_set = Set.empty (module S)