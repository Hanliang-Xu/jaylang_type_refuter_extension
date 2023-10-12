open Core
open Jayil
open Dj_common

(* The abstract env is a map from concrete id to abstract value.
   The abstract store is a map from abstract ctx to a set of abstract env.
   Note puttinng envs into a set is one choice to _merge_ envs.

   To enhance the flexibility,
   we made an explicit abstract map, which is a map from concrete id to abstact value.

   Maps can be merged at different granularities, e.g. to merge `m1` and `m2`
   m1 = {a -> {1,2}}
   m2 = {a -> {1}, b -> 2}

   we can merge them at set-level:
   m12s = [{a -> {1,2}; {a -> {1}, {b -> 2}}]

   we can also merge them at key-level:
   m12k = [{a -> {1,2}, {b -> 2}}

   The difference is one possible mapping case `{a -> 2}, {b -> 2}` is created by `m12k`.
*)

module Make (Ctx : Finite_callstack.C) = struct
  module AVal = struct
    module T = struct
      type t =
        | AInt
        | ABool of bool
        | AClosure of Id.t * Abs_exp.t * Ctx.t
        (* | ARecord of t Map.M(Id).t  *)
        | ARecord of Set.M(Id).t * Ctx.t

      and aenv = t Map.M(Id).t [@@deriving equal, compare, hash, sexp]

      let pp fmter = function
        | AInt -> Fmt.string fmter "n"
        | ABool b -> Fmt.pf fmter "%a" Std.pp_bo b
        | AClosure (x, _, ctx) -> Fmt.pf fmter "<%a ! %a>" Id.pp x Ctx.pp ctx
        | ARecord (keys, ctx) ->
            Fmt.pf fmter "{%a ! %a}" (Std.pp_set Id.pp) keys Ctx.pp ctx
    end

    include T
    include Comparator.Make (T)
  end

  module AEnv = struct
    module T = struct
      type t = AVal.aenv [@@deriving equal, compare, hash, sexp]
    end

    include T
    include Comparator.Make (T)

    let show aenv = Sexp.to_string_hum (sexp_of_t aenv)

    let pp fmter env =
      Fmt.Dump.iter_bindings Std.iteri_core_map Fmt.nop Id.pp AVal.pp fmter env
  end

  (* type aval_set = Set.M(AVal).t *)
  type env_set = Set.M(AEnv).t [@@deriving equal, compare, hash, sexp]

  let show_env_set es = Sexp.to_string_hum (sexp_of_env_set es)

  let pp_env_set : env_set Fmt.t =
    Fmt.iter ~sep:(Fmt.any ";@ ") Std.iter_core_set AEnv.pp

  let pp_aval_set : Set.M(AVal).t Fmt.t =
    Fmt.iter ~sep:(Fmt.any ";@ ") Std.iter_core_set AVal.pp

  module AStore = struct
    (* multimap *)

    type t = env_set Map.M(Ctx).t [@@deriving equal, compare, hash, sexp]

    let show s = Sexp.to_string_hum (sexp_of_t s)

    let pp fmter astore =
      (* Fmt.Dump.iter_bindings iter Fmt.nop Ctx.pp pp_env_set fmter store *)
      Fmt.iter_bindings ~sep:(Fmt.any ";@ ") Std.iteri_core_map
        (Fmt.pair ~sep:(Fmt.any " -> ") Ctx.pp (Fmt.box pp_env_set))
        fmter astore

    let weight astore =
      astore |> Map.data
      |> List.map ~f:(fun set ->
             set |> Set.to_list |> List.map ~f:Map.length
             |> List.sum (module Int) ~f:Fn.id)
      |> List.sum (module Int) ~f:Fn.id
  end

  type astore = AStore.t

  let safe_add_store store ctx aenv =
    Map.update store ctx ~f:(function
      | Some envs -> Set.add envs aenv
      | None -> Set.singleton (module AEnv) aenv)

  let pp_aenv_deep store ctx fmter aenv =
    let open AVal in
    let ctx_set = Hash_set.of_list (module Ctx) [ ctx ] in
    let rec pp_env fmter aenv =
      Fmt.Dump.iter_bindings Std.iteri_core_map Fmt.nop Id.pp pp_val fmter aenv
    and pp_val fmter = function
      | AInt -> Fmt.string fmter "n"
      | ABool b -> Fmt.pf fmter "%a" Std.pp_bo b
      | AClosure (x, _, ctx) -> (
          match Hash_set.strict_add ctx_set ctx with
          | Ok _ ->
              let aenvs = Map.find_exn store ctx |> Set.to_list in
              Fmt.pf fmter "<%a @ <%a->%a>>" Id.pp x Ctx.pp ctx
                (Fmt.list pp_env) aenvs
          | Error _ -> Fmt.pf fmter "<%a @ !%a>" Id.pp x Ctx.pp ctx)
      | ARecord (keys, ctx) -> (
          Fmt.pf fmter "{%a" (Std.pp_set Id.pp) keys ;
          match Hash_set.strict_add ctx_set ctx with
          | Ok _ ->
              let aenvs = Map.find_exn store ctx |> Set.to_list in
              Fmt.pf fmter "{%a %a}}" Ctx.pp ctx (Fmt.list pp_env) aenvs
          | Error _ -> Fmt.pf fmter "!%a}" Ctx.pp ctx)
    in
    pp_env fmter aenv

  module Abs_result = struct
    module Imp = struct
      module T = struct
        type t = AVal.t * AStore.t [@@deriving equal, compare, hash, sexp]
      end

      include T
      include Comparator.Make (T)

      let pp = Fmt.Dump.pair AVal.pp AStore.pp
    end

    let empty = Set.empty (module Imp)
    let only v = Set.singleton (module Imp) v

    include Imp
  end

  type result_set = Set.M(Abs_result).t [@@deriving equal, compare, hash, sexp]

  let pp_result_set : result_set Fmt.t =
    Fmt.iter Std.iter_core_set Abs_result.pp

  let show_result_set rset = Sexp.to_string_hum (sexp_of_result_set rset)
end
