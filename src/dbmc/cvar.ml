open Core

module T = struct
  type cat =
    | Fun_to_callsite of {
        block_f : Id.t;
        block_callsite : Id.t;
        callsite : Id.t;
      }
    | Callsite_to_fun of {
        callsite : Id.t;
        block_callsite : Id.t;
        block_f : Id.t;
      }
    | Condsite of { condsite : Id.t; beta : bool }

  and t = {
    lookups : Id.t list;
    cat : cat;
    r_stk : (Rstack.T.t[@printer Std.ignore2]);
    complete_name : (string[@ignore] [@printer Std.ignore2]);
    picked_name : (string[@ignore] [@printer Std.ignore2]);
  }
  [@@deriving sexp, compare, equal, hash, show { with_path = false }]
end

include T
include Comparator.Make (T)

module Cvar_partial = struct
  module T = struct
    type t = Id.t list * cat * (Rstack.T.t[@printer Std.ignore2])
    [@@deriving sexp, compare, equal, hash, show { with_path = false }]
  end

  include T
  include Comparator.Make (T)
end

let print cvar =
  let cat_string =
    match cvar.cat with
    | Fun_to_callsite fc ->
        Fmt.str "%a$%a_to_%a" Id.pp fc.callsite Id.pp fc.block_f Id.pp
          fc.block_callsite
    | Callsite_to_fun cf ->
        Fmt.str "%a$%a_to_%a" Id.pp cf.callsite Id.pp cf.block_callsite Id.pp
          cf.block_f
    | Condsite cos -> Fmt.str "%a$%B" Id.pp cos.condsite cos.beta
  in
  Fmt.str "(%a)%s" Lookup_stack.pp cvar.lookups cat_string

let pp_print = Fmt.of_to_string print

type fc_out = {
  xs_out : Id.t list;
  site : Id.t;
  stk_out : (Rstack.T.t[@printer Std.ignore2]);
  f_out : Id.t;
  cvar : t;
}
[@@deriving sexp, show { with_path = false }]

type fc = {
  xs_in : Id.t list;
  stk_in : (Rstack.T.t[@printer Std.ignore2]);
  fun_in : Id.t;
  outs : fc_out list;
}
[@@deriving sexp, show { with_path = false }]

type cf_in = {
  xs_in : Id.t list;
  stk_in : (Rstack.T.t[@printer Std.ignore2]);
  fun_in : Id.t;
  cvar : t;
}
[@@deriving sexp, show { with_path = false }]

type cf = {
  xs_out : Id.t list;
  stk_out : (Rstack.T.t[@printer Std.ignore2]);
  site : Id.t;
  f_out : Id.t;
  ins : cf_in list;
}
[@@deriving sexp, show { with_path = false }]

let mk_condsite_beta lookups condsite r_stk beta : Cvar_partial.t =
  let cat = Condsite { condsite; beta } in
  (lookups, cat, r_stk)

let mk_fun_to_callsite lookups r_stk fun_in f_out site : Cvar_partial.t =
  let cat =
    Fun_to_callsite
      { block_f = fun_in; block_callsite = f_out; callsite = site }
  in
  (lookups, cat, r_stk)

let mk_callsite_to_fun lookups r_stk callsite f_out fun_in : Cvar_partial.t =
  let cat =
    Callsite_to_fun { callsite; block_callsite = f_out; block_f = fun_in }
  in
  (lookups, cat, r_stk)

let str_of_complete counter = Printf.sprintf "C_%d_c" counter

let str_of_picked counter = Printf.sprintf "C_%d_p" counter
