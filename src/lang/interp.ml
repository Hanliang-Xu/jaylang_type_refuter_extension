
open Core
open Ast
open Expr

module Value = struct
  open Constraints

  type _ t =
    (* all languages *)
    | VInt : int -> 'a t
    | VBool : bool -> 'a t
    | VFunClosure : { param : Ident.t ; body : 'a Expr.t ; env : 'a env } -> 'a t
    | VVariant : { label : VariantLabel.t ; payload : 'a t } -> 'a t
    | VRecord : 'a t RecordLabel.Map.t -> 'a t
    | VTypeMismatch : 'a t
    | VAbort : 'a t (* this results from `EAbort` or `EAssert (EBool false)` *)
    | VDiverge : 'a t (* this results from `EDiverge` or `EAssume (EBool false)` *)
    (* embedded only *)
    | VId : 'a embedded_only t
    | VFrozen : 'a Expr.t -> 'a embedded_only t
    (* desugared only *)
    | VKind : 'a desugared_only t
    (* bluejay only *)
    | VList : 'a t list -> 'a bluejay_only t
    | VMultiArgFunClosure : { params : Ident.t list ; body : 'a Expr.t ; env : 'a env } -> 'a bluejay_only t
    (* types in desugared and embedded *)
    | VTypeInt : 'a bluejay_or_desugared t
    | VTypeBool : 'a bluejay_or_desugared t
    | VTypeRecord : 'a t RecordLabel.Map.t -> 'a bluejay_or_desugared t
    | VTypeArrow : { domain : 'a t ; codomain : 'a t } -> 'a bluejay_or_desugared t
    | VTypeArrowD : { binding : Ident.t ; domain : 'a t ; codomain : 'a Expr.t } -> 'a bluejay_or_desugared t
    | VTypeRefinement : { tau : 'a t ; predicate : 'a t } -> 'a bluejay_or_desugared t
    | VTypeIntersect : (VariantTypeLabel.t * 'a t * 'a t) list -> 'a bluejay_or_desugared t
    | VTypeMu : { var : Ident.t ; body : 'a Expr.t } -> 'a bluejay_or_desugared t
    | VTypeVariant : (VariantTypeLabel.t * 'a t) list -> 'a bluejay_or_desugared t
    (* types in bluejay only *)
    | VTypeList : 'a t -> 'a bluejay_only t
    | VTypeForall : { type_variables : Ident.t list ; tau : 'a Expr.t } -> 'a bluejay_only t

  and 'a env = 'a t Ident.Map.t

  let check_pattern (type a) (v : a t) (p : a Pattern.t) : bool =
    match p with
    | PAny | PVariable _ -> true
    | PVariant { variant_label ; _ } -> begin
      match v with
      | VVariant { label ; _ } ->
        VariantLabel.equal variant_label label
      | _ -> false
    end
    | PEmptyList -> begin
      match v with
      | VList [] -> true
      | _ -> false
    end
    | PDestructList _ -> begin
      match v with
      | VList (_ :: _) -> true
      | _ -> false
    end
end

open Value

module Env = struct
  type 'a t = 'a Value.env

  let empty : 'a t = Ident.Map.empty

  let add (env : 'a t) (id : Ident.t) (v : 'a Value.t) : 'a t =
    Map.set env ~key:id ~data:v

  let fetch (env : 'a t) (id : Ident.t) : 'a Value.t =
    Map.find_exn env id
end

(* TODO: benchmark the performance of this *)
module CPS_Error_M (R : sig type t end) = struct
  module Err = struct
    type t = Abort | Diverge | Type_mismatch
    (* we might consider adding an Assert_false and Assume_false construct *)
  end

  module C = Monadlib.Continuation.Make (struct type r = R.t end)

  module T = struct
    type 'a m = ('a, Err.t) result C.m

    let bind (x : 'a m) (f : 'a -> 'b m) : 'b m = 
      C.bind x (function
        | Ok r -> f r
        | Error e -> C.return (Error e)
      )

    let return (a : 'a) : 'a m =
      C.return
      @@ Result.return a
  end

  include Monadlib.Monad.Make (T)

  (* unit is needed to surmount the value restriction *)
  let abort (type a) (() : unit) : a m =
    C.return
    @@ Result.fail Err.Abort

  let diverge (type a) (() : unit) : a m =
    C.return
    @@ Result.fail Err.Diverge

  let type_mismatch (type a) (() : unit) : a m =
    C.return
    @@ Result.fail Err.Type_mismatch
end

let eval_exp (type a) (e : a Expr.t) : a Value.t =
  let module M = CPS_Error_M (struct type t = a Value.t end) in
  let open M in
  let zero () = type_mismatch () in
  let rec eval (e : a Expr.t) (env : a Env.t) : a Value.t m =
    match e with
    (* direct values *)
    | EInt i -> return (VInt i)
    | EBool b -> return (VBool b)
    | EVar id -> return @@ Env.fetch env id
    | ETypeInt -> return VTypeInt
    | ETypeBool -> return VTypeBool
    | ETypeMu { var ; body } -> return (VTypeMu { var ; body })
    | ETypeForall { type_variables ; tau } -> return (VTypeForall { type_variables ; tau })
    | EKind -> return VKind
    | EAbort -> abort ()
    | EDiverge -> diverge ()
    | EFunction { param ; body } -> return (VFunClosure { param ; body ; env })
    | EMultiArgFunction { params ; body } -> return (VMultiArgFunClosure { params ; body ; env })
    | EFreeze e -> return (VFrozen e)
    | EId -> return VId
    (* inputs *) (* TODO: make this not random but instead from an input stream *)
    | EPick_i -> return (VInt (Random.int_incl Int.min_value Int.max_value))
    | EPick_b -> return (VBool (Random.bool ()))
    (* simple propogation *)
    | EVariant { label ; payload } ->
      let%bind payload = eval payload env in
      return (VVariant { label ; payload = payload })
    | EList e_list ->
      let%bind ls = M.list_map (fun e -> eval e env) e_list in
      return (VList ls)
    | ETypeList tau ->
      let%bind vtau = eval tau env in
      return (VTypeList vtau)
    | ETypeArrow { domain ; codomain } ->
      let%bind domain = eval domain env in
      let%bind codomain = eval codomain env in
      return (VTypeArrow { domain ; codomain })
    | ETypeArrowD { binding ; domain ; codomain } -> (* TODO: is this right? *)
      let%bind domain = eval domain env in
      return (VTypeArrowD { binding ; domain ; codomain })
    | ETypeRefinement { tau ; predicate } ->
      let%bind tau = eval tau env in
      let%bind predicate = eval predicate env in
      return (VTypeRefinement { tau ; predicate })
    | ETypeIntersect e_ls ->
      let%bind ls = M.list_map (fun (label, tau, tau') ->
        let%bind vtau = eval tau env in
        let%bind vtau' = eval tau' env in
        return (label, vtau, vtau')
        ) e_ls
      in
      return (VTypeIntersect ls)
    | ETypeVariant e_ls ->
      let%bind ls = M.list_map (fun (label, tau) ->
        let%bind vtau = eval tau env in
        return (label, vtau)
        ) e_ls
      in
      return (VTypeVariant ls)
    | ERecord record_body ->
      let%bind new_record = eval_record_body record_body env in
      return (VRecord new_record)
    | ETypeRecord record_type_body ->
      let%bind new_record = eval_record_body record_type_body env in
      return (VTypeRecord new_record)
    | EThaw e ->
      let%bind v_frozen = eval e env in
      let%orzero (VFrozen e_frozen) = v_frozen in
      eval e_frozen env
    (* bindings *)
    | EAppl { func ; arg } -> begin
      let%bind vfunc = eval func env in
      let%bind arg = eval arg env in
      match vfunc with
      | VFunClosure { param ; body ; env } ->
        eval body (Env.add env param arg)
      | VId -> return arg
      | VMultiArgFunClosure { params ; body ; env } -> begin
        match params with
        | [] -> type_mismatch ()
        | [ param ] ->
          eval body (Env.add env param arg)
        | param :: params ->
          eval (EMultiArgFunction { params ; body }) (Env.add env param arg)
        end
      | _ -> type_mismatch ()
    end
    | ELet { var ; body ; cont } -> eval_let var ~body ~cont env
    | ELetTyped { typed_var = { var ; _ } ; body ; cont } -> eval_let var ~body ~cont env (* TODO: consider if we should eval and ignore the tau expression *)
    | ELetWrap { typed_var = { var ; _ } ; body ; cont } -> eval_let var ~body ~cont env
    | EIgnore { ignored ; cont } ->
      let%bind _ = eval ignored env in
      eval cont env
    (* operations *)
    | EListCons (e_hd, e_tl) -> begin
      let%bind hd = eval e_hd env in
      let%bind tl = eval e_tl env in
      let%orzero (VList ls) = tl in
      return (VList (hd :: ls))
    end
    | EBinop { left ; binop ; right } -> begin
      let%bind a = eval left env in
      let%bind b = eval right env in
      match binop, a, b with
      | BPlus, VInt n1, VInt n2                 -> return (VInt (n1 + n2))
      | BMinus, VInt n1, VInt n2                -> return (VInt (n1 - n2))
      | BTimes, VInt n1, VInt n2                -> return (VInt (n1 * n2))
      | BDivide, VInt n1, VInt n2 when n2 <> 0  -> return (VInt (n1 / n2))
      | BModulus, VInt n1, VInt n2 when n2 <> 0 -> return (VInt (n1 % n2))
      | BEqual, VInt n1, VInt n2                -> return (VBool (n1 = n2))
      | BEqual, VBool b1, VBool b2              -> return (VBool Bool.(b1 = b2))
      | BNeq, VInt n1, VInt n2                  -> return (VBool (n1 <> n2))
      | BNeq, VBool b1, VBool b2                -> return (VBool Bool.(b1 <> b2))
      | BLessThan, VInt n1, VInt n2             -> return (VBool (n1 < n2))
      | BLeq, VInt n1, VInt n2                  -> return (VBool (n1 <= n2))
      | BGreaterThan, VInt n1, VInt n2          -> return (VBool (n1 > n2))
      | BGeq, VInt n1, VInt n2                  -> return (VBool (n1 >= n2))
      | BAnd, VBool b1, VBool b2                -> return (VBool (b1 && b2))
      | BOr, VBool b1, VBool b2                 -> return (VBool (b1 || b2))
      | _ -> type_mismatch ()
    end
    | ENot e_not_body ->
      let%bind e_b = eval e_not_body env in
      let%orzero (VBool b) = e_b in
      return (VBool (not b))
    | EAssert e_assert_body ->
      let%bind e_b = eval e_assert_body env in
      let%orzero (VBool b) = e_b in
      if b
      then return (VRecord RecordLabel.Map.empty)
      else abort ()
    | EAssume e_assert_body ->
      let%bind e_b = eval e_assert_body env in
      let%orzero (VBool b) = e_b in
      if b
      then return (VRecord RecordLabel.Map.empty)
      else diverge ()
    | EIf { cond ; true_body ; false_body } ->
      let%bind e_b = eval cond env in
      let%orzero (VBool b) = e_b in
      if b
      then eval true_body env
      else eval false_body env
    | EProject { record ; label } ->
      let%bind r = eval record env in
      let%orzero (VRecord record_body) = r in (* Note: this means we can't project from a record type *)
      let%orzero (Some v) = Map.find record_body label in
      return v
    (* casing *)
    | EMatch _ -> failwith "unimplemented match"
      (* let%bind v = eval subject env in
      List.find patterns ~f:(fun ()) *)
    | ECase _ -> failwith "unimplemented case"
    (* let funs *)
    | ELetFunRec _ -> failwith "unimplemented let fun rec"
    | ELetFun _ -> failwith "unimplemented let fun"

    and eval_let (var : Ident.t) ~(body : a Expr.t) ~(cont : a Expr.t) (env : a Env.t) : a Value.t m =
      let%bind v = eval body env in
      eval cont (Env.add env var v)

    and eval_record_body (record_body : a Expr.t RecordLabel.Map.t) (env : a Env.t) : a Value.t RecordLabel.Map.t m =
      Map.fold record_body ~init:(return RecordLabel.Map.empty) ~f:(fun ~key ~data:e acc_m ->
        let%bind acc = acc_m in
        let%bind v = eval e env in
        return (Map.set acc ~key ~data:v)
      )
  in
  (eval e Env.empty) (function
    | Ok r -> r
    | Error Type_mismatch -> VTypeMismatch
    | Error Abort -> VAbort
    | Error Diverge -> VDiverge
  )



