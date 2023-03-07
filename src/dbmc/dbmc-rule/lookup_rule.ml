open Core
open Dj_common
open Jayil
open Jayil.Ast
open Rule
open Types
module U = Unrolls.U_dbmc
module Log = Log.Export.CMLOG

let create_counter (state : Global_state.t) (term_detail : Term_detail.t) key =
  Hashtbl.update state.smt_lists key ~f:(function
    | Some i -> i
    | None ->
        Global_state.add_phi state term_detail (Riddler.list_head key) ;
        0)

let fetch_counter (state : Global_state.t) key =
  let new_i =
    Hashtbl.update_and_return state.smt_lists key ~f:(function
      | Some i -> i + 1
      | None -> failwith (Fmt.str "why not inited : %a" Lookup_key.pp key))
  in
  new_i - 1

(*
   Status promotion:
   The status of a lookup depends om the status of messages from its sublookups.
   The status promotion is a lattice and any status can only be promoted once.

   The workflow is:
   1. If not top-status:
   1.a.1 check the status from the incoming message
   1.b.1 check the sub-lookups to get the current status
   1.b.2     record the current status
   1.b.3 promote the status in the message if necessary

   The difference of 1.a and 1.b comes from whether 
*)

(* CAUTION: `sub` is not the id by a lookup.
         `sub` is the _id_ for lookup task creation. However, multiple streams can push to this `sub`.
         `pub` is the _id_ for a lookup result.

         These lookups won't call this function:
         Leaf-lookup has no `pub` because itself is a sub and a pub.
         Both-lookup has two `pub`s.
         Map-lookup and MapSeq has one `pub`.
*)
(* Option.iter (Rule_action.source_of action) ~f:(fun source ->
    term_detail.sub_lookups <- term_detail.sub_lookups @ [ source ]) ; *)

let fold_lookups_status map lookups =
  let open Lookup_status in
  List.fold_until lookups ~init:Good
    ~f:(fun acc_s lookup ->
      match Hashtbl.find map lookup with
      | Some (detail : Term_detail.t) -> (
          match (detail.status, acc_s) with
          | Good, _ -> Stop Good
          | Complete, _ -> Continue Complete
          | Fail, Complete -> Continue Complete
          | Fail, _ -> Continue Fail)
      | None -> Stop Good)
    ~finish:Fn.id

let set_status (td : Term_detail.t) status = td.status <- status

let promote_status (td : Term_detail.t) status' =
  let open Lookup_status in
  match (td.status, status') with
  | Good, Good -> Some Good
  | Good, _ -> Some status'
  | Complete, _ -> None (* failwith "[complete] why here" *)
  | Fail, _ -> None (* failwith "[fail] why here" *)

let promote_result (target : Lookup_key.t) map (td : Term_detail.t)
    (r : Lookup_result.t) status' =
  (* Fmt.pr "[Push]%a @." (Observe.pp_key_with_detail map) (target, td) ;
        Fmt.pr "[Push] <- %a;%a(%a) @." Lookup_key.pp r.from Lookup_status.pp_short
     status' Lookup_status.pp_short r.status ; *)
  match promote_status td status' with
  | Some Complete ->
      set_status td Complete ;
      Some Lookup_result.(status_as r Complete)
  | Some status'' ->
      set_status td status'' ;
      Some Lookup_result.(status_as r status'')
  | None ->
      (* Fmt.pr "[Push] %a =/=> @." Lookup_status.pp_short td.status ; *)
      None

let register run_task unroll (state : Global_state.t)
    (term_detail : Term_detail.t) target source =
  let open Rule_action in
  let add_phi = Global_state.add_phi state term_detail in
  let set_status = set_status term_detail in
  let add_sub_preconds cond =
    term_detail.sub_preconds <- term_detail.sub_preconds @ [ cond ]
  in
  let add_sublookup key =
    term_detail.sub_lookups <- term_detail.sub_lookups @ [ key ]
  in
  let promote_result = promote_result target state.term_detail_map in
  let rec run ?(sub_lookup = false) source =
    match source with
    | Withered -> set_status Lookup_status.Fail
    | Leaf ->
        set_status Lookup_status.Complete ;
        U.by_return unroll target (Lookup_result.complete target)
    | Direct e ->
        if sub_lookup
        then (
          add_sublookup e.pub ;
          U.by_id_u unroll target e.pub)
        else
          U.by_filter_map_u unroll target e.pub (fun r ->
              promote_result term_detail r r.status) ;
        Log.debug (fun m ->
            m "[Direct]%a <- %a(%B) @." Lookup_key.pp target Lookup_key.pp e.pub
              sub_lookup) ;
        run_task e.pub
    | Map e ->
        U.by_filter_map_u unroll target e.pub (fun r ->
            promote_result term_detail (e.map r) r.status) ;
        run_task e.pub
    | MapSeq e ->
        create_counter state term_detail target ;
        let f r =
          let i = fetch_counter state target in
          let r', phis = e.map i r in
          add_phi (Riddler.list_append target i (Riddler.and_ phis)) ;
          promote_result term_detail r' r.status
        in
        U.by_filter_map_u unroll target e.pub f ;
        run_task e.pub
    | Both e ->
        U.by_filter_map2_u unroll target e.pub1 e.pub2 (fun (v1, v2) ->
            let joined_status = Lookup_status.join v1.status v2.status in
            promote_result term_detail (Lookup_result.ok target) joined_status) ;
        run_task e.pub1 ;
        run_task e.pub2
    | Chain e ->
        let precond = ref false in
        add_sub_preconds precond ;
        let part1_cb key (r : Lookup_result.t) =
          if Lookup_status.is_complete_or_fail r.status then precond := true ;
          Lookup_status.iter_ok r.status (fun () ->
              match e.next key r with
              | Some edge -> run ~sub_lookup:true edge
              | None -> ()) ;
          (* Fmt.pr "[Chain][P1]%a <- %a(%a) @." Lookup_key.pp target Lookup_key.pp
               r.from Lookup_status.pp_short r.status ;
             Fmt.pr "[Chain][P1](%B)%a @." !precond
               (Observe.pp_key_with_detail state.term_detail_map)
               (target, term_detail) ; *)
          Lwt.return_unit
        in
        U.by_bind_u unroll target e.pub part1_cb ;
        run_task e.pub
    | Sequence e ->
        create_counter state term_detail target ;
        let precond = ref false in
        add_sub_preconds precond ;
        let part1_cb _key (r : Lookup_result.t) =
          if Lookup_status.is_complete_or_fail r.status then precond := true ;
          Lookup_status.iter_ok r.status (fun () ->
              let i = fetch_counter state target in
              let next = e.next i r in
              match next with
              | Some (phi_i, edge) ->
                  add_phi @@ Riddler.list_append target i phi_i ;
                  run ~sub_lookup:true edge
              | None -> add_phi (Riddler.list_append target i Riddler.false_)) ;
          Lwt.return_unit
        in
        U.by_bind_u unroll target e.pub part1_cb ;
        run_task e.pub
    | Or_list e ->
        if e.unbound then create_counter state term_detail target ;
        List.iter e.elements ~f:(run ~sub_lookup)
  in

  run source ;
  let need_pre_push =
    (not (List.is_empty term_detail.sub_preconds))
    || not (List.is_empty term_detail.sub_lookups)
  in
  if need_pre_push
  then (
    let pre_push (r : Lookup_result.t) =
      (* Fmt.pr "[PrePush] %a <- %a;%a@." Lookup_key.pp target Lookup_key.pp r.from
         Lookup_status.pp_short r.status ; *)
      if List.for_all term_detail.sub_preconds ~f:Ref.( ! )
      then
        let status' =
          fold_lookups_status state.term_detail_map term_detail.sub_lookups
        in
        (* Fmt.pr "[PrePush] <=%a@." Lookup_status.pp_short status' ; *)
        promote_result term_detail r status'
      else Some r
    in
    U.set_pre_push unroll target pre_push ;
    Log.debug (fun m ->
        m "[Reg-%B] %a %d@." need_pre_push Lookup_key.pp target
          (List.length term_detail.sub_preconds)))

module type S = sig
  val state : Global_state.t
  val config : Global_config.t
  val block_map : Cfg.block Jayil.Ast.Ident_map.t
end

module Make (S : S) = struct
  open Rule_action

  let rule_main v _p (key : Lookup_key.t) =
    (Leaf, Some (Riddler.discover_main_with_picked key v))

  let rule_nonmain v _p (key : Lookup_key.t) =
    let key_first = Lookup_key.to_first key S.state.first in
    ( Map
        { pub = key_first; map = (fun r -> Lookup_result.from_as key r.status) },
      Some (Riddler.discover_non_main key key_first v) )

  let discovery_main (p : Discovery_main_rule.t) (key : Lookup_key.t) =
    rule_main (Some p.v) p.v key

  let discovery_nonmain (p : Discovery_nonmain_rule.t) (key : Lookup_key.t) =
    rule_nonmain (Some p.v) p key

  let input (p : Input_rule.t) (key : Lookup_key.t) =
    Hash_set.add S.state.input_nodes key ;
    if p.is_in_main then rule_main None p key else rule_nonmain None p key

  let alias (p : Alias_rule.t) (key : Lookup_key.t) =
    (Direct { pub = p.x' }, Some (Riddler.eq_with_picked key p.x'))

  let not_ (p : Not_rule.t) (key : Lookup_key.t) =
    ( Map { pub = p.x'; map = (fun r -> Lookup_result.from_as key r.status) },
      Some (Riddler.not_with_picked key p.x') )

  let binop (p : Binop_rule.t) (key : Lookup_key.t) =
    ( Both { pub1 = p.x1; pub2 = p.x2 },
      Some (Riddler.binop_with_picked key p.bop p.x1 p.x2) )

  let record_start p (key : Lookup_key.t) =
    let ({ r = key_r; lbl } : Record_start_rule.t) = p in
    let next i r =
      if Lookup_result.is_ok r
      then
        let key_rv = r.from in
        let rv = Cfg.clause_body_of_x key_rv.block key_rv.x in
        match rv with
        | Value_body (Value_record (Record_value rv)) -> (
            match Ident_map.Exceptionless.find lbl rv with
            | Some (Var (field, _)) ->
                let key_l = Lookup_key.with_x key_rv field in
                let phi_i = Riddler.record_start key key_r key_rv key_l in
                let action = Direct { pub = key_l } in
                Some (phi_i, action)
            | None -> None)
        | _ -> None
      else None
    in
    (Sequence { pub = key_r; next }, None)

  let cond_top p (key : Lookup_key.t) =
    let ({ cond_case_info = cb; condsite_block } : Cond_top_rule.t) = p in
    let key_x, key_x2, beta =
      let _paired, condsite_stack =
        Rstack.pop_at_condtop key.r_stk (cb.condsite, Id.cond_fid cb.choice)
      in
      ( Lookup_key.of3 key.x condsite_stack condsite_block,
        Lookup_key.of3 cb.cond condsite_stack condsite_block,
        cb.choice )
    in
    let next _ r =
      (* true *)
      (* if Riddler.eager_check S.state S.config key_x2
           [ Riddler.eqv key_x2 (Value_bool choice) ] *)
      if Lookup_result.is_ok r then Some (Direct { pub = key_x }) else None
    in
    (Chain { pub = key_x2; next }, Some (Riddler.cond_top key key_x key_x2 beta))

  let cond_btm p (key : Lookup_key.t) =
    let ({ x'; cond_both } : Cond_btm_rule.t) = p in
    let next _ r =
      if Lookup_result.is_ok r
      then
        (* let eager_result = Checker.eager_check S.state S.config term_c [] in
           Fmt.pr "[CondBtm]%a <- %a\nEager=%B\n" Lookup_key.pp key Lookup_key.pp
             r.from eager_result ; *)
        (* if eager_result *)
        if true
        then
          let elements =
            List.filter_map [ true; false ] ~f:(fun beta ->
                let cond_case_block_opt =
                  if beta then cond_both.then_ else cond_both.else_
                in
                (* Riddler.step_eager_check S.state S.config term_c
                      [ Riddler.eqv term_c (Value_bool beta) ]
                      S.config.stride *)
                match cond_case_block_opt with
                | Some cond_case_block ->
                    let key_ret =
                      Lookup_key.return_key_of_cond key beta cond_case_block
                    in
                    Some (Direct { pub = key_ret })
                | None -> None)
          in
          Some (Or_list { elements; unbound = false })
        else None
      else None
    in
    (Chain { pub = x'; next }, Some (Riddler.cond_bottom key p.x' p.cond_both))

  let fun_enter_local p (key : Lookup_key.t) =
    let fid = key.block.id in
    let callsites = Lookup_key.get_callsites key.r_stk key.block in
    let elements =
      List.map callsites ~f:(fun callsite ->
          let callsite_block, x', x'', x''' =
            Cfg.fun_info_of_callsite callsite S.block_map
          in
          match Rstack.pop key.r_stk (x', fid) with
          | Some callsite_stack ->
              let key_f = Lookup_key.of3 x'' callsite_stack callsite_block in
              let next this_key r =
                if Lookup_result.is_ok r
                then
                  let key_arg =
                    Lookup_key.of3 x''' callsite_stack callsite_block
                  in
                  Some (Direct { pub = key_arg })
                else None
              in
              Chain { pub = key_f; next }
          | None -> failwith "why Rstack.pop fails here")
    in
    ( Or_list { elements; unbound = false },
      Some
        (Riddler.fun_enter_local key key.block.id callsites S.state.block_map)
    )

  let fun_enter_nonlocal p (key : Lookup_key.t) =
    let callsites = Lookup_key.get_callsites key.r_stk key.block in
    let elements =
      List.map callsites ~f:(fun callsite ->
          let callsite_block, x', x'', _x''' =
            Cfg.fun_info_of_callsite callsite S.block_map
          in
          match Rstack.pop key.r_stk (x', key.block.id) with
          | Some callsite_stack ->
              let key_f = Lookup_key.of3 x'' callsite_stack callsite_block in
              let next i r =
                if Lookup_result.is_ok r
                then
                  let fv_block = Cfg.find_block_by_id r.from.x S.block_map in
                  let key_arg = Lookup_key.of3 key.x r.from.r_stk fv_block in
                  let phi_i =
                    Riddler.fun_enter_nonlocal key key_f r.from key.block.id
                      key_arg
                  in
                  let action = Direct { pub = key_arg } in
                  Some (phi_i, action)
                else None
              in
              Sequence { pub = key_f; next }
          | None -> failwith "why Rstack.pop fails here")
    in
    (Or_list { elements; unbound = true }, None)

  let fun_exit (p : Fun_exit_rule.t) (key : Lookup_key.t) =
    let next (_key : Lookup_key.t) (rf : Lookup_result.t) =
      if Lookup_result.is_ok rf
      then
        let fid = rf.from.x in
        if List.mem p.fids fid ~equal:Id.equal
        then
          let key_ret = Lookup_key.get_f_return S.block_map fid key in
          Some (Direct { pub = key_ret })
        else None
      else None
    in
    ( Chain { pub = p.xf; next },
      Some (Riddler.fun_exit key p.xf p.fids S.state.block_map) )

  let pattern p (key : Lookup_key.t) =
    let ({ x'; pat; _ } : Pattern_rule.t) = p in
    let f i (r : Lookup_result.t) =
      (* OB1: For some patterns, we can immediately know the result of the matching:
           when the returning value is a literal value. We can use it in the interpreter.
           We lose this information when the lookup go through a conditional block or
           some binop. *)
      (* OB2: The pattern matching can tolerate infeasible cases caused by the analysis,
         because the literal value is incorrect. A conditional block can use this result
         to go into a then-block or a else-block.
      *)
      let key_rv = r.from in
      let rv = Cfg.clause_body_of_x key_rv.block key_rv.x in
      let phis, _matched =
        match (pat, rv) with
        | Any_pattern, _
        | Fun_pattern, Value_body (Value_function _)
        | Int_pattern, Value_body (Value_int _)
        | Int_pattern, Input_body
        | Bool_pattern, Value_body (Value_bool _) ->
            let phi1 = Riddler.eqv_with_picked key x' (Value_bool true) in
            let phi2 = Riddler.picked_pattern key x' pat in

            ([ phi1; phi2 ], true)
        | Rec_pattern ids, Value_body (Value_record (Record_value rv)) ->
            let have_all =
              Ident_set.for_all (fun id -> Ident_map.mem id rv) ids
            in
            let phi =
              Riddler.picked_record_pattern key x' (Value_bool have_all) pat
            in
            ([ phi ], true)
        | Strict_rec_pattern ids, Value_body (Value_record (Record_value rv)) ->
            let have_all =
              Ident_set.equal ids (Ident_set.of_enum @@ Ident_map.keys rv)
            in
            let phi =
              Riddler.picked_record_pattern key x' (Value_bool have_all) pat
            in
            ([ phi ], true)
        | Rec_pattern _, _ | _, Value_body _ ->
            let phi1 = Riddler.eqv_with_picked key x' (Value_bool false) in
            let phi2 = Riddler.picked_pattern key x' pat in

            ([ phi1; phi2 ], false)
        | _, _ ->
            (* TODO: some binops contain type information for patterns *)
            (* TODO: and for previous pattern match *)
            let phi = Riddler.picked_pattern key x' pat in
            ([ phi ], false)
      in
      (* Fmt.pr "[Pattern][%B] %a | %a |%a\n" matched Lookup_key.pp key
         Jayil.Ast_pp.pp_pattern pat Lookup_key.pp key_rv ; *)
      let eq_key'_rv = Riddler.eq x' key_rv in
      let picked_rv = Riddler.picked key_rv in
      (Lookup_result.from_as key r.status, picked_rv :: eq_key'_rv :: phis)
    in
    (MapSeq { pub = x'; map = f }, None)

  let assume _p (key : Lookup_key.t) =
    (Withered, Some (Riddler.mismatch_with_picked key))

  let assert_ _p (key : Lookup_key.t) =
    (Withered, Some (Riddler.mismatch_with_picked key))

  let abort p (key : Lookup_key.t) =
    if Lookup_key.equal key (Lookup_key.start S.config.target key.block)
       (* TODO: take care of direct `abort` in the main block *)
    then rule_nonmain None p key
    else (Withered, Some (Riddler.mismatch_with_picked key))

  let mismatch (key : Lookup_key.t) =
    (Withered, Some (Riddler.mismatch_with_picked key))
end
