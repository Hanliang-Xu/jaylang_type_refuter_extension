open Monadlib
open Batteries
open Jayil
open Jay
open Jay_ast
open Translation_context

module TranslationMonad : sig
  include Monad.S

  val run : translation_context -> 'a m -> 'a
  (** Run the monad to completion *)

  val run_verbose : translation_context -> 'a m -> 'a * translation_context
  (** Run the monad to completion *)

  val fresh_name : string -> string m
  (** Create a fresh (ie. alphatized) name *)

  val fresh_var : string -> Ast.var m
  (** Create a fresh var *)

  val add_instrument_var : Ast.var -> unit m
  (** Add an jayil var to note that it was added during instrumentation (and
      that it does not have an associated pre-instrumentation clause) *)

  val add_jayil_jay_mapping : Ast.var -> Jay_ast.expr_desc -> unit m
  (** Map an jayil var to a jay expression *)

  val add_jay_expr_mapping : Jay_ast.expr_desc -> Jay_ast.expr_desc -> unit m
  (** Map a jay expression to another jay expression *)

  val add_jay_var_mapping : Jay_ast.ident -> Jay_ast.ident -> unit m
  (** Map a jay ident to another ident. *)

  val add_jay_type_mapping : Jay_ast.Ident_set.t -> Jay_ast.type_sig -> unit m
  (** Map a set of jay idents to a jay type. *)

  val add_const : Ast.var -> unit m
  val get_const_vars : Ast.var list m
  val update_jayil_jay_maps : Ast.var Ast.Var_map.t -> unit m
  val update_instrumented_tags : ISet.t -> unit m
  val is_jay_instrumented : int -> bool m
  val add_jay_instrumented : int -> unit m

  val jayil_jay_maps : Jay_to_jayil_maps.t m
  (** Retrieve the jayil-to-jay maps from the monad *)

  val freshness_string : string m
  (** Retrieve the freshness string from the monad *)

  val acontextual_recursion : bool m
  (** Retrieve the contextual recursion boolean value *)

  val sequence : 'a m list -> 'a list m
  (** Convert a list of monadic values into a singular monadic value *)

  val list_fold_left_m : ('acc -> 'el -> 'acc m) -> 'acc -> 'el list -> 'acc m
  (** Left fold in the monad *)

  val list_fold_right_m : ('el -> 'acc -> 'acc m) -> 'el list -> 'acc -> 'acc m
  (** Right fold in the monad *)

  val ( @@@ ) : ('a -> 'b m) -> 'a m -> 'b m
  (** @@ in the monad *)
end = struct
  include Monad.Make (struct
    type 'a m = translation_context -> 'a

    let return (x : 'a) : 'a m = fun _ -> x
    let bind (x : 'a m) (f : 'a -> 'b m) : 'b m = fun ctx -> f (x ctx) ctx
  end)

  let run ctx m = m ctx
  let run_verbose ctx m = (m ctx, ctx)

  let fresh_name name ctx =
    let n = ctx.tc_fresh_name_counter in
    ctx.tc_fresh_name_counter <- n + 1 ;
    name ^ ctx.tc_fresh_suffix_separator ^ string_of_int n

  let fresh_var name ctx =
    let name' = fresh_name name ctx in
    Ast.Var (Ast.Ident name', None)

  let add_instrument_var v ctx =
    let (Ast.Var (i, _)) = v in
    let jayil_jay_maps = ctx.tc_jayil_jay_mappings in
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.add_jay_instrument_var jayil_jay_maps i None

  let add_jayil_jay_mapping v_key e_val ctx =
    let (Ast.Var (i_key, _)) = v_key in
    let jayil_jay_maps = ctx.tc_jayil_jay_mappings in
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.add_jayil_var_jay_expr_mapping jayil_jay_maps i_key
        e_val

  let add_jay_expr_mapping k_expr v_expr ctx =
    let jayil_jay_maps = ctx.tc_jayil_jay_mappings in
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.add_jay_expr_to_expr_mapping jayil_jay_maps k_expr
        v_expr

  let add_jay_var_mapping k_var v_var ctx =
    let jayil_jay_maps = ctx.tc_jayil_jay_mappings in
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.add_jay_var_to_var_mapping jayil_jay_maps k_var v_var

  let add_jay_type_mapping k_idents v_type ctx =
    let jayil_jay_maps = ctx.tc_jayil_jay_mappings in
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.add_jay_idents_to_type_mapping jayil_jay_maps k_idents
        v_type

  let add_const v ctx =
    let jayil_jay_maps = ctx.tc_jayil_jay_mappings in
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.add_const_var jayil_jay_maps v

  let get_const_vars ctx =
    let jayil_jay_maps = ctx.tc_jayil_jay_mappings in
    Jay_to_jayil_maps.get_const_vars jayil_jay_maps

  let update_jayil_jay_maps mappings ctx =
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.update_jayil_mappings ctx.tc_jayil_jay_mappings mappings

  let update_instrumented_tags instrument_tags ctx =
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.update_instrumented_tags ctx.tc_jayil_jay_mappings
        instrument_tags

  let is_jay_instrumented tag ctx =
    Jay_to_jayil_maps.is_jay_instrumented ctx.tc_jayil_jay_mappings tag

  let add_jay_instrumented tag ctx =
    ctx.tc_jayil_jay_mappings <-
      Jay_to_jayil_maps.add_jay_instrumented ctx.tc_jayil_jay_mappings tag

  let jayil_jay_maps ctx = ctx.tc_jayil_jay_mappings
  let freshness_string ctx = ctx.tc_fresh_suffix_separator
  let acontextual_recursion ctx = not ctx.tc_contextual_recursion

  let rec sequence ms =
    match ms with
    | [] -> return []
    | h :: t ->
        let%bind h' = h in
        let%bind t' = sequence t in
        return @@ (h' :: t')

  let rec list_fold_left_m fn acc els =
    match els with
    | [] -> return acc
    | h :: t ->
        let%bind acc' = fn acc h in
        list_fold_left_m fn acc' t

  let rec list_fold_right_m fn els acc =
    match els with
    | [] -> return acc
    | h :: t ->
        let%bind acc' = list_fold_right_m fn t acc in
        fn h acc'

  let ( @@@ ) f x = bind x f
end

let ident_map_map_m (fn : 'a -> 'b TranslationMonad.m)
    (m : 'a Jay_ast.Ident_map.t) : 'b Jay_ast.Ident_map.t TranslationMonad.m =
  let open TranslationMonad in
  m |> Jay_ast.Ident_map.enum
  |> Enum.map (fun (k, v) ->
         let%bind v' = fn v in
         return (k, v'))
  |> List.of_enum |> sequence |> map List.enum
  |> map Jay_ast.Ident_map.of_enum

(* *** Generalized monadic transformations for expressions with reader and
   writer support. *** *)

type ('env, 'out) m_env_out_expr_transformer =
  ('env -> Jay_ast.expr_desc -> (Jay_ast.expr_desc * 'out) TranslationMonad.m) ->
  'env ->
  Jay_ast.expr_desc ->
  (Jay_ast.expr_desc * 'out) TranslationMonad.m

let rec m_env_out_transform_expr
    (transformer : ('env, 'out) m_env_out_expr_transformer)
    (combiner : 'out -> 'out -> 'out) (default : 'out) (env : 'env)
    (e_desc : Jay_ast.expr_desc) : (Jay_ast.expr_desc * 'out) TranslationMonad.m
    =
  let recurse = m_env_out_transform_expr transformer combiner default in
  let open TranslationMonad in
  let transform_funsig (Jay_ast.Funsig (name, args, body)) =
    let%bind body', out' = recurse env body in
    let%bind body'', out'' = transformer recurse env body' in
    return @@ (Jay_ast.Funsig (name, args, body''), combiner out' out'')
  in
  let%bind (e' : Jay_ast.expr_desc), (out' : 'out) =
    let e = e_desc.body in
    let og_tag = e_desc.tag in
    match e with
    | Jay_ast.Var x ->
        return @@ ({ tag = og_tag; body = Jay_ast.Var x }, default)
    | Jay_ast.Input ->
        return @@ ({ tag = og_tag; body = Jay_ast.Input }, default)
    | Jay_ast.Function (x, e1) ->
        let%bind e1', out1 = recurse env e1 in
        return @@ ({ tag = og_tag; body = Jay_ast.Function (x, e1') }, out1)
    | Jay_ast.Appl (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ({ tag = og_tag; body = Jay_ast.Appl (e1', e2') }, combiner out1 out2)
    | Jay_ast.Let (x, e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.Let (x, e1', e2') },
             combiner out1 out2 )
    | Jay_ast.LetRecFun (funsigs, e1) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind funsigs', outs =
          map List.split @@ sequence @@ List.map transform_funsig funsigs
        in
        let out = List.fold_left combiner out1 outs in
        return
        @@ ({ tag = og_tag; body = Jay_ast.LetRecFun (funsigs', e1') }, out)
    | Jay_ast.LetFun (funsig, e1) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind funsig', out2 = transform_funsig funsig in
        return
        @@ ( { tag = og_tag; body = Jay_ast.LetFun (funsig', e1') },
             combiner out1 out2 )
    | Jay_ast.Plus (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ({ tag = og_tag; body = Jay_ast.Plus (e1', e2') }, combiner out1 out2)
    | Jay_ast.Minus (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.Minus (e1', e2') },
             combiner out1 out2 )
    | Jay_ast.Times (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.Times (e1', e2') },
             combiner out1 out2 )
    | Jay_ast.Divide (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.Divide (e1', e2') },
             combiner out1 out2 )
    | Jay_ast.Modulus (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.Modulus (e1', e2') },
             combiner out1 out2 )
    | Jay_ast.Equal (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.Equal (e1', e2') },
             combiner out1 out2 )
    | Jay_ast.Neq (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ({ tag = og_tag; body = Jay_ast.Neq (e1', e2') }, combiner out1 out2)
    | Jay_ast.LessThan (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.LessThan (e1', e2') },
             combiner out1 out2 )
    | Jay_ast.Leq (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ({ tag = og_tag; body = Jay_ast.Leq (e1', e2') }, combiner out1 out2)
    | Jay_ast.GreaterThan (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.GreaterThan (e1', e2') },
             combiner out1 out2 )
    | Jay_ast.Geq (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ({ tag = og_tag; body = Jay_ast.Geq (e1', e2') }, combiner out1 out2)
    | Jay_ast.And (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ({ tag = og_tag; body = Jay_ast.And (e1', e2') }, combiner out1 out2)
    | Jay_ast.Or (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ({ tag = og_tag; body = Jay_ast.Or (e1', e2') }, combiner out1 out2)
    | Jay_ast.Not e1 ->
        let%bind e1', out1 = recurse env e1 in
        return @@ ({ tag = og_tag; body = Jay_ast.Not e1' }, out1)
    | Jay_ast.If (e1, e2, e3) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        let%bind e3', out3 = recurse env e3 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.If (e1', e2', e3') },
             combiner (combiner out1 out2) out3 )
    | Jay_ast.Int n ->
        return @@ ({ tag = og_tag; body = Jay_ast.Int n }, default)
    | Jay_ast.Bool b ->
        return @@ ({ tag = og_tag; body = Jay_ast.Bool b }, default)
    | Jay_ast.Record r ->
        let%bind mappings, outs =
          r |> Jay_ast.Ident_map.enum
          |> Enum.map (fun (k, v) ->
                 let%bind v', out' = recurse env v in
                 return ((k, v'), out'))
          |> List.of_enum |> sequence |> map List.enum |> map Enum.uncombine
        in
        let r' = Jay_ast.Ident_map.of_enum mappings in
        let out = Enum.fold combiner default outs in
        return @@ ({ tag = og_tag; body = Jay_ast.Record r' }, out)
    | Jay_ast.RecordProj (e1, l) ->
        let%bind e1', out = recurse env e1 in
        return @@ ({ tag = og_tag; body = Jay_ast.RecordProj (e1', l) }, out)
    | Jay_ast.Match (e0, branches) ->
        let%bind e0', out0 = recurse env e0 in
        (* let () = failwith @@ Jay_ast.show_expr_desc e0' in *)
        let%bind branches', outs =
          map List.split @@ sequence
          @@ List.map
               (fun (pat, expr) ->
                 let%bind expr', out' = recurse env expr in
                 return ((pat, expr'), out'))
               branches
        in
        let out = List.fold_left combiner out0 outs in
        return @@ ({ tag = og_tag; body = Jay_ast.Match (e0', branches') }, out)
    | Jay_ast.VariantExpr (l, e) ->
        let%bind e', out = recurse env e in
        return @@ ({ tag = og_tag; body = Jay_ast.VariantExpr (l, e') }, out)
    | Jay_ast.List es ->
        let%bind es', outs =
          map List.split @@ sequence @@ List.map (fun e -> recurse env e) es
        in
        let out = List.fold_left combiner default outs in
        return @@ ({ tag = og_tag; body = Jay_ast.List es' }, out)
    | Jay_ast.ListCons (e1, e2) ->
        let%bind e1', out1 = recurse env e1 in
        let%bind e2', out2 = recurse env e2 in
        return
        @@ ( { tag = og_tag; body = Jay_ast.ListCons (e1', e2') },
             combiner out1 out2 )
    | Jay_ast.Assert e ->
        let%bind e', out = recurse env e in
        return @@ ({ tag = og_tag; body = Jay_ast.Assert e' }, out)
    | Jay_ast.Assume e ->
        let%bind e', out = recurse env e in
        return @@ ({ tag = og_tag; body = Jay_ast.Assume e' }, out)
    | Jay_ast.Error x ->
        return @@ ({ tag = og_tag; body = Jay_ast.Error x }, default)
  in

  let%bind e'', out'' = transformer recurse env e' in
  return (e'', combiner out' out'')

type 'env m_env_expr_transformer =
  ('env -> Jay_ast.expr_desc -> Jay_ast.expr_desc TranslationMonad.m) ->
  'env ->
  Jay_ast.expr_desc ->
  Jay_ast.expr_desc TranslationMonad.m

let m_env_transform_expr (transformer : 'env m_env_expr_transformer)
    (env : 'env) (e : Jay_ast.expr_desc) : Jay_ast.expr_desc TranslationMonad.m
    =
  let open TranslationMonad in
  let transformer'
      (recurse : 'env -> Jay_ast.expr_desc -> (Jay_ast.expr_desc * unit) m) env
      (e : Jay_ast.expr_desc) : (Jay_ast.expr_desc * unit) m =
    let recurse' env e =
      let%bind e'', () = recurse env e in
      return e''
    in
    let%bind e' = transformer recurse' env e in
    return (e', ())
  in
  let%bind e', () =
    m_env_out_transform_expr transformer' (fun _ _ -> ()) () env e
  in
  return e'

type m_expr_transformer =
  (Jay_ast.expr_desc -> Jay_ast.expr_desc TranslationMonad.m) ->
  Jay_ast.expr_desc ->
  Jay_ast.expr_desc TranslationMonad.m

let m_transform_expr (transformer : m_expr_transformer) (e : Jay_ast.expr_desc)
    : Jay_ast.expr_desc TranslationMonad.m =
  let open TranslationMonad in
  let transformer' (recurse : unit -> Jay_ast.expr_desc -> Jay_ast.expr_desc m)
      () (e : Jay_ast.expr_desc) : Jay_ast.expr_desc TranslationMonad.m =
    let recurse' e = recurse () e in
    transformer recurse' e
  in
  m_env_transform_expr transformer' () e
