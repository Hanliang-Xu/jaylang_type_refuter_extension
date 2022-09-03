open Jay
open Jayil

type t [@@deriving show]

val empty : bool -> t

(* **** Setter functions **** *)

val add_jayil_var_on_expr_mapping : t -> Ast.ident -> Jay_ast.expr_desc -> t
(** Add a mapping from an odefa ident to the natodefa expression that, when
    flattened, produced its odefa clause. *)

val add_on_expr_to_expr_mapping :
  t -> Jay_ast.expr_desc -> Jay_ast.expr_desc -> t
(** Add a mapping between two natodefa expressions. These pairs are added when
    let rec, list, and variant expressions/patterns are desuraged. *)

val add_on_var_to_var_mapping : t -> Jay_ast.ident -> Jay_ast.ident -> t
(** Add a mapping between two natodefa idents. These pairs are to be added when
    an ident is renamed during alphatization. *)

val add_on_idents_to_type_mapping :
  t -> Jay_ast.Ident_set.t -> Jay_ast.type_sig -> t
(** Add a mapping between a set of natodefa idents to a natodefa type. These are
    used to identify record expressions/patterns that are the result of
    desugaring lists or variants. *)

val add_jay_instrument_var : t -> Ast.ident -> Ast.ident option -> t
(** Add an mapping from an odefa ident added during instrumentation to an odefa
    ident option, corresponding to some pre-instrumentation ident it aliases.
    The value is None if there is not a corresponding aliased ident (e.g. vars
    added during match expr flattening). *)

(* **** Getter functions **** *)

val get_natodefa_equivalent_expr : t -> Ast.ident -> Jay_ast.expr_desc option
(** Get the natodefa expression that the odefa clause that the odefa var
    identifies maps to. *)

val get_natodefa_equivalent_expr_exn : t -> Ast.ident -> Jay_ast.expr_desc

val get_type_from_idents : t -> Ast.Ident_set.t -> Jay_ast.type_sig
(** Get the natodefa type that a set of record labels corresponds to. If there
    is no mapping that exists, return a record type by default. *)

val odefa_to_on_aliases : t -> Ast.ident list -> Jay_ast.expr_desc list

val get_odefa_var_opt_from_natodefa_expr :
  t -> Jay_ast.expr_desc -> Ast.var option
(** Given a natodefa expression, returns the corresponding variable in desugared
    odefa. *)

val get_natodefa_inst_map : t -> Ast.ident option Ast.Ident_map.t
