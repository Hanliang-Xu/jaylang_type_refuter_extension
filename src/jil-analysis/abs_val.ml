open Core
open Fix
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
        (* | ARecord of Set.M(Id).t * Ctx.t *)
        | ARecord of Id.t Map.M(Id).t * Ctx.t
      [@@deriving equal, compare, hash, sexp]

      let pp_record0 fmter rmap =
        (Fmt.Dump.iter_bindings Std.iteri_core_map Fmt.nop Id.pp Id.pp)
          fmter rmap

      let pp fmter = function
        | AInt -> Fmt.string fmter "n"
        | ABool b -> Fmt.pf fmter "%a" Std.pp_bo b
        | AClosure (x, _, ctx) -> Fmt.pf fmter "<%a ! %a>" Id.pp x Ctx.pp ctx
        | ARecord (rmap, ctx) ->
            Fmt.pf fmter "{%a ! %a}" pp_record0 rmap Ctx.pp ctx
    end

    include T
    include Comparator.Make (T)
  end

  module AEnv_raw = struct
    module T = struct
      type t = AVal.t Map.M(Id).t [@@deriving equal, compare, hash, sexp]
    end

    include T
    include Comparator.Make (T)

    let show aenv = Sexp.to_string_hum (sexp_of_t aenv)

    let pp fmter env =
      Fmt.Dump.iter_bindings Std.iteri_core_map Fmt.nop Id.pp AVal.pp fmter env
  end

  module AEnv = struct
    module HC = HashCons.ForHashedType (struct
      type t = AEnv_raw.t

      let equal = AEnv_raw.equal
      let hash = AEnv_raw.hash
    end)

    module T = struct
      type t = AEnv_raw.t HashCons.cell

      let compare = HashCons.compare
      let hash = HashCons.hash
      let equal = HashCons.equal
      let hash_fold_t state t = hash_fold_int state (HashCons.id t)
      let sexp_of_t e = AEnv_raw.sexp_of_t (HashCons.data e)
      let t_of_sexp e = HC.make (AEnv_raw.t_of_sexp e)
      let pp fmt e = AEnv_raw.pp fmt (HashCons.data e)
    end

    include T
    include Comparator.Make (T)

    let add_binding ~key ~data (e : t) : t =
      HC.make (Map.add_exn (HashCons.data e) ~key ~data)
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

    let weight (astore : t) : int =
      astore |> Map.data
      |> List.map ~f:(fun set ->
             set |> Set.to_list
             |> List.map ~f:(fun env -> Map.length (HashCons.data env))
             |> List.sum (module Int) ~f:Fn.id)
      |> List.sum (module Int) ~f:Fn.id

    let weight_env astore ctx aenv =
      let visited = Hash_set.of_list (module Ctx) [ ctx ] in
      let rec loop aenv =
        aenv |> Map.to_alist
        |> List.map ~f:(fun (k, v) ->
               match v with
               | AVal.AClosure (_, _, ctx') -> (
                   match Hash_set.strict_add visited ctx' with
                   | Ok _ ->
                       Map.find_exn astore ctx' |> Set.to_list
                       |> List.map ~f:loop
                       |> List.sum (module Int) ~f:Fn.id
                   | Error _ -> 1)
               | _ -> 1)
        |> List.sum (module Int) ~f:Fn.id
      in
      loop aenv
  end

  type astore = AStore.t

  let safe_add_store (store : astore) ctx (aenv : AEnv.t) =
    Map.update store ctx ~f:(function
      | Some envs -> Set.add envs aenv
      | None -> Set.singleton (module AEnv) aenv)

  let pp_aenv_deep (store : AStore.t) ctx fmter (aenv : AEnv.t) =
    let open AVal in
    let ctx_set = Hash_set.of_list (module Ctx) [ ctx ] in
    let rec pp_env fmter aenv =
      Fmt.Dump.iter_bindings Std.iteri_core_map Fmt.nop Id.pp pp_val fmter
        (HashCons.data aenv)
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
      | ARecord (rmap, ctx) -> (
          Fmt.pf fmter "{%a" pp_record0 rmap ;
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
