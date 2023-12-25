open Core
open Jayil.Ast
open Dj_common (* exposes Concrete_stack *)
open Concolic_exceptions (* these help convey status of evaluation *)
open Dvalue (* just to expose constructors *)

module ILog = Log.Export.ILog

(* Ident for conditional bool. *)
let cond_fid b = if b then Ident "$tt" else Ident "$ff"

(*
  --------------------------------------
  BEGIN DEBUG FUNCTIONS FROM INTERPRETER   
  --------------------------------------

  Unless labeled, I just keep these called "session", when really they're
  an eval session (see session.mli).
*)

module Debug =
  struct
    let debug_update_read_node session x stk =
      let open Session.Eval in
      match (session.is_debug, session.mode) with
      | true, Session.Mode.With_full_target (_, target_stk) ->
          let r_stk = Rstack.relativize target_stk stk in
          let block = Cfg.(find_reachable_block x session.block_map) in
          let key = Lookup_key.of3 x r_stk block in
          (* This is commented out in the interpreter, where I got the code *)
          (* Fmt.pr "@[Update Get to %a@]\n" Lookup_key.pp key; *)
          Hashtbl.change session.term_detail_map key ~f:(function
            | Some td -> Some { td with get_count = td.get_count + 1 }
            | None -> failwith "not term_detail")
      | _, _ -> ()

    let debug_update_write_node session x stk =
      let open Session.Eval in
      match (session.is_debug, session.mode) with
      | true, Session.Mode.With_full_target (_, target_stk) ->
          let r_stk = Rstack.relativize target_stk stk in
          let block = Cfg.(find_reachable_block x session.block_map) in
          let key = Lookup_key.of3 x r_stk block in
          (* This is commented out in the interpreter, where I got the code *)
          (* Fmt.pr "@[Update Set to %a@]\n" Lookup_key.pp key; *)
          Hashtbl.change session.term_detail_map key ~f:(function
            | Some td -> Some { td with is_set = true }
            | None -> failwith "not term_detail")
      | _, _ -> ()

    let debug_stack session x stk (v, _) =
      let open Session.Eval in
      match (session.is_debug, session.mode) with
      | true, Session.Mode.With_full_target (_, target_stk) ->
          let rstk = Rstack.relativize target_stk stk in
          Fmt.pr "@[%a = %a\t\t R = %a@]\n" Id.pp x Dvalue.pp v Rstack.pp rstk
      | _, _ -> ()

    let raise_if_with_stack session x stk v =
      let open Session.Eval in
      match session.mode with
      | Session.Mode.With_full_target (target_x, target_stk) when Ident.equal target_x x ->
          if Concrete_stack.equal_flip target_stk stk
          then raise (Found_target { x; stk; v })
          else
            Fmt.(
              pr "found %a at stack %a, expect %a\n" pp_ident x Concrete_stack.pp
                target_stk Concrete_stack.pp stk)
      | Session.Mode.With_target_x target_x when Ident.equal target_x x ->
          raise (Found_target { x; stk; v })
      | _ -> ()

    let alert_lookup session x stk =
      let open Session.Eval in
      match session.mode with
      | Session.Mode.With_full_target (_, target_stk) ->
          let r_stk = Rstack.relativize target_stk stk in
          let block = Cfg.(find_reachable_block x session.block_map) in
          let key = Lookup_key.of3 x r_stk block in
          Fmt.epr "@[Update Alert to %a\t%a@]\n" Lookup_key.pp key Concrete_stack.pp
            stk ;
          Hash_set.add session.lookup_alert key
      | _ -> ()

    let rec same_stack s1 s2 =
      let open Session.Eval in
      match (s1, s2) with
      | (cs1, fid1) :: ss1, (cs2, fid2) :: ss2 ->
          Ident.equal cs1 cs2 && Ident.equal fid1 fid2 && same_stack ss1 ss2
      | [], [] -> true
      | _, _ -> false

    let debug_clause ~eval_session x v stk =
      let open Session.Eval in
      ILog.app (fun m -> m "@[%a = %a@]" Id.pp x Dvalue.pp v) ;

      (match eval_session.debug_mode with
      | Session.Mode.Debug.Debug_clause clause_cb -> clause_cb x stk (Dvalue.value_of_t v)
      | Session.Mode.Debug.No_debug -> ()) ;

      raise_if_with_stack eval_session x stk v ;
      debug_stack eval_session x stk (v, stk) ;
      ()
  end

(*
  ------------------------------------
  END DEBUG FUNCTIONS FROM INTERPRETER   
  ------------------------------------
*)

(*
  ------------------------------
  BEGIN HELPERS TO READ FROM ENV   
  ------------------------------
*)

module Fetch =
  struct

    let fetch_val_with_stk ~(eval_session : Session.Eval.t) ~stk env (Var (x, _)) :
        Dvalue.t * Concrete_stack.t =
      let res = Ident_map.find x env in (* find the variable and stack in the environment *)
      Debug.debug_update_read_node eval_session x stk ; 
      res

    let fetch_val ~(eval_session : Session.Eval.t) ~stk env x : Dvalue.t =
      fst (fetch_val_with_stk ~eval_session ~stk env x) (* find variable and stack, then discard stack *)

    let fetch_stk ~(eval_session : Session.Eval.t) ~stk env x : Concrete_stack.t =
      snd (fetch_val_with_stk ~eval_session ~stk env x) (* find variable and stack, then discard variable *)

    let fetch_val_to_direct ~(eval_session : Session.Eval.t) ~stk env vx : value =
      match fetch_val ~eval_session ~stk env vx with
      | Direct v -> v
      | _ -> failwith "eval to non direct value"

    let fetch_val_to_bool ~(eval_session : Session.Eval.t) ~stk env vx : bool =
      match fetch_val ~eval_session ~stk env vx with
      | Direct (Value_bool b) -> b
      | _ -> failwith "eval to non bool"

    let check_pattern ~(eval_session : Session.Eval.t) ~stk env vx pattern : bool =
      match (fetch_val ~eval_session ~stk env vx, pattern) with
      | Direct (Value_int _), Int_pattern -> true
      | Direct (Value_bool _), Bool_pattern -> true
      | Direct (Value_function _), _ -> failwith "fun must be a closure"
      | Direct (Value_record _), _ -> failwith "record must be a closure"
      | RecordClosure (Record_value record, _), Rec_pattern key_set ->
          Ident_set.for_all (fun id -> Ident_map.mem id record) key_set
      | RecordClosure (Record_value record, _), Strict_rec_pattern key_set ->
          Ident_set.equal key_set (Ident_set.of_enum @@ Ident_map.keys record)
      | FunClosure (_, _, _), Fun_pattern -> true
      | _, Any_pattern -> true
      | _, _ -> false

  end

(*
  ----------------------------
  END HELPERS TO READ FROM ENV   
  ----------------------------
*)


(*
  ----------
  BEGIN EVAL
  ----------

  This section is basically an interpreter injected with concolic logic.
  It is an evaluation within a single concolic session.
*)

let generate_lookup_key (x : Jayil.Ast.ident) (stk : Dj_common.Concrete_stack.t) : Lookup_key.t =
  { x
  ; r_stk = Rstack.from_concrete stk
  ; block = Dj_common.Cfg.{ id = x ; clauses = [] ; kind = Main } }

let rec eval_exp
  ~(eval_session : Session.Eval.t) (* Note: is mutable *)
  ~(conc_session : Session.Concolic.t)
  (stk : Concrete_stack.t)
  (env : Dvalue.denv)
  (e : expr)
  : Dvalue.denv * Dvalue.t * Session.Concolic.t
  =
  ILog.app (fun m -> m "@[-> %a@]\n" Concrete_stack.pp stk);
  (match eval_session.mode with
  | With_full_target (_, target_stk) ->
      let r_stk = Rstack.relativize target_stk stk in
      Hashtbl.change eval_session.rstk_picked r_stk ~f:(function
        | Some true -> Some false
        | Some false -> raise (Run_into_wrong_stack (Jayil.Ast_tools.first_id e, stk))
        | None-> None)
  | _ -> ());
  let Expr clauses = e in
  let (denv, conc_session), vs =
    List.fold_map
      clauses
      ~init:(env, conc_session)
      ~f:(fun (env, cs) clause ->
        let denv, v, cs = eval_clause ~eval_session ~conc_session:cs stk env clause
        in (denv, cs), v) 
  in
  (denv, List.last_exn vs, conc_session)

and eval_clause
  ~(eval_session : Session.Eval.t)
  ~(conc_session : Session.Concolic.t)
  (stk : Concrete_stack.t)
  (env : Dvalue.denv)
  (clause : clause)
  : Dvalue.denv * Dvalue.t * Session.Concolic.t
  =
  let Clause (Var (x, _), cbody) = clause in
  (match eval_session.max_step with 
  | None -> ()
  | Some max_step ->
      Int.incr eval_session.step;
      if !(eval_session.step) > max_step then raise (Reach_max_step (x, stk)) else ()
    );
  
  Debug.debug_update_write_node eval_session x stk;
  let x_key = generate_lookup_key x stk in
  let (v, conc_session) : Dvalue.t * Session.Concolic.t =
    match cbody with
    | Value_body ((Value_function vf) as v) ->
      (* x = fun ... ; *)
      let retv = FunClosure (x, vf, env) in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, retv) eval_session;
      retv, Session.Concolic.add_key_eq_val conc_session x_key v
    | Value_body ((Value_record r) as v) ->
      (* x = { ... } ; *)
      let retv = RecordClosure (r, env) in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, retv) eval_session;
      retv, Session.Concolic.add_key_eq_val conc_session x_key v
    | Value_body v -> 
      (* x = <bool or int> ; *)
      let retv = Direct v in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, retv) eval_session;
      retv, Session.Concolic.add_key_eq_val conc_session x_key v
    | Var_body vx ->
      (* x = y ; *)
      let Var (y, _) = vx in
      let ret_val, ret_stk = Fetch.fetch_val_with_stk ~eval_session ~stk env vx in
      Session.Eval.add_alias (x, stk) (y, ret_stk) eval_session;
      let y_key = generate_lookup_key y ret_stk in 
      ret_val, Session.Concolic.add_alias conc_session x_key y_key
    | Conditional_body (cx, e1, e2) ->
      (* x = if y then e1 else e2 ; *)
      let Var (y, _) = cx in
      let cond_val, condition_stk = Fetch.fetch_val_with_stk ~eval_session ~stk env cx in
      let cond_bool = match cond_val with Direct (Value_bool b) -> b | _ -> failwith "non-bool condition" in
      let condition_key = generate_lookup_key y condition_stk in
      let this_branch = Branch.Runtime.{ branch_key = x_key ; condition_key ; direction = Branch.Direction.of_bool cond_bool } in

      (* enter/hit branch *)
      let conc_session = Session.Concolic.enter_branch conc_session this_branch in

      let e = if cond_bool then e1 else e2 in
      let stk' = Concrete_stack.push (x, cond_fid cond_bool) stk in

      (* note that [eval_session] gets mutated when evaluating the branch *)
      let res = Result.try_with (fun () -> eval_exp ~eval_session ~conc_session stk' env e) in
      begin
        (* This is so ugly. I really need to get rid of the exceptions and use variants *)
        match res with
        | Error (Found_abort (v, conc_session)) ->
          (* can just say x = x and continue aborting to wrap up and let no future formulas get added *)
          (* TODO: figure out why pick branch is not getting added on the deepest aborted branch *)
          raise @@ Found_abort (v, Session.Concolic.exit_branch conc_session)
        | Error (Reach_max_step _) -> () (* TODO *)
        | _ -> () (* continue normally on Ok or any other exception *)
      end;
      let ret_env, ret_val, conc_session = Result.ok_exn res in (* Bubbles exceptions *)
      let (Var (ret_id, _) as last_v) = Jayil.Ast_tools.retv e in (* last defined value in the branch *)
      let _, ret_stk = Fetch.fetch_val_with_stk ~eval_session ~stk:stk' ret_env last_v in

      (* say the ret_key is equal to x now, then clear out branch *)
      let ret_key = generate_lookup_key ret_id ret_stk in
      let conc_session = Session.Concolic.add_alias conc_session x_key ret_key in
      let conc_session = Session.Concolic.exit_branch conc_session in
      Session.Eval.add_alias (x, stk) (ret_id, ret_stk) eval_session;
      ret_val, conc_session
    | Input_body ->
      (* x = input ; *)
      let n = eval_session.input_feeder (x, stk) in
      let retv = Direct (Value_int n) in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, retv) eval_session;
      let conc_session = Session.Concolic.add_alias conc_session x_key x_key in
      retv, Session.Concolic.add_input conc_session x retv
    | Appl_body (vf, (Var (x_arg, _) as varg)) -> begin
      (* x = f y ; *)
      match Fetch.fetch_val ~eval_session ~stk env vf with
      | FunClosure (fid, Function_value (Var (param, _), body), fenv) ->
        (* vx2 is the argument that fills in param *)
        let arg, arg_stk = Fetch.fetch_val_with_stk ~eval_session ~stk env varg in
        let stk' = Concrete_stack.push (x, fid) stk in
        let env' = Ident_map.add param (arg, stk') fenv in
        Session.Eval.add_alias (param, stk) (x_arg, arg_stk) eval_session;

        (* enter function: say arg is same as param *)
        (* let Var (xid, _) = vf in *)
        (* let f_stk = Fetch.fetch_stk ~eval_session ~stk env vf in *)
        (* let key_f = generate_lookup_key xid f_stk in *) (* this was only needed when we had the siblings and dependencies *)
        let key_param = generate_lookup_key param stk' in
        let key_arg = generate_lookup_key x_arg arg_stk in
        let conc_session = Session.Concolic.add_alias conc_session key_param key_arg in

        (* returned value of function *)
        let ret_env, ret_val, conc_session = eval_exp ~eval_session ~conc_session stk' env' body in
        let (Var (ret_id, _) as last_v) = Jayil.Ast_tools.retv body in
        let ret_stk = Fetch.fetch_stk ~eval_session ~stk:stk' ret_env last_v in
        Session.Eval.add_alias (x, stk) (ret_id, ret_stk) eval_session;

        (* exit function: *)
        let ret_key = generate_lookup_key ret_id ret_stk in
        ret_val, Session.Concolic.add_alias conc_session x_key ret_key
      | _ -> failwith "appl to a non fun"
      end
    | Match_body (vy, p) ->
      (* x = y ~ <pattern> ; *)
      let match_res = Value_bool (Fetch.check_pattern ~eval_session ~stk env vy p) in
      let retv = Direct (match_res) in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, retv) eval_session;
      let Var (y, _) = vy in
      let match_key = generate_lookup_key y stk in
      let x_key_exp = Riddler.key_to_var x_key in
      let conc_session = Session.Concolic.add_formula conc_session @@ Solver.SuduZ3.ifBool x_key_exp in (* x has a bool value it will take on *)
      let conc_session =
        Session.Concolic.add_formula conc_session
        @@ Solver.SuduZ3.eq (Solver.SuduZ3.project_bool x_key_exp) (Riddler.is_pattern match_key p) (* x is same as result of match *)
      in
      retv, conc_session
    | Projection_body (v, label) -> begin
      match Fetch.fetch_val ~eval_session ~stk env v with
      | RecordClosure (Record_value r, denv) ->
        let Var (proj_x, _) as proj_v = Ident_map.find label r in
        let retv, stk' = Fetch.fetch_val_with_stk ~eval_session ~stk denv proj_v in
        Session.Eval.add_alias (x, stk) (proj_x, stk') eval_session;
        (* TODO: records have limited concolic functionality *)
        let Var (v_ident, _) = v in
        let v_stk = Fetch.fetch_stk ~eval_session ~stk env v in
        let record_key = generate_lookup_key v_ident v_stk in
        let proj_key = generate_lookup_key proj_x stk' in
        retv, Session.Concolic.add_alias conc_session x_key proj_key
      | Direct (Value_record (Record_value _record)) ->
        failwith "project should also have a closure"
      | _ -> failwith "project on a non record"
      end
    | Not_body vy ->
      (* x = not y ; *)
      let v = Fetch.fetch_val_to_direct ~eval_session ~stk env vy in 
      let bv =
        match v with
        | Value_bool b -> Value_bool (not b)
        | _ -> failwith "incorrect not"
      in
      let retv = Direct bv in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, retv) eval_session;
      let (Var (y, _)) = vy in
      let y_key = generate_lookup_key y stk in
      retv, Session.Concolic.add_formula conc_session @@ Riddler.not_ x_key y_key
    | Binary_operation_body (vy, op, vz) ->
      (* x = y op z *)
      let v1 = Fetch.fetch_val_to_direct ~eval_session ~stk env vy
      and v2 = Fetch.fetch_val_to_direct ~eval_session ~stk env vz in
      let v =
        match op, v1, v2 with
        | Binary_operator_plus, Value_int n1, Value_int n2                  -> Value_int  (n1 + n2)
        | Binary_operator_minus, Value_int n1, Value_int n2                 -> Value_int  (n1 - n2)
        | Binary_operator_times, Value_int n1, Value_int n2                 -> Value_int  (n1 * n2)
        | Binary_operator_divide, Value_int n1, Value_int n2                -> Value_int  (n1 / n2)
        | Binary_operator_modulus, Value_int n1, Value_int n2               -> Value_int  (n1 mod n2)
        | Binary_operator_less_than, Value_int n1, Value_int n2             -> Value_bool (n1 < n2)
        | Binary_operator_less_than_or_equal_to, Value_int n1, Value_int n2 -> Value_bool (n1 <= n2)
        | Binary_operator_equal_to, Value_int n1, Value_int n2              -> Value_bool (n1 = n2)
        | Binary_operator_equal_to, Value_bool b1, Value_bool b2            -> Value_bool (Bool.(b1 = b2))
        | Binary_operator_and, Value_bool b1, Value_bool b2                 -> Value_bool (b1 && b2)
        | Binary_operator_or, Value_bool b1, Value_bool b2                  -> Value_bool (b1 || b2)
        | Binary_operator_not_equal_to, Value_int n1, Value_int n2          -> Value_bool (n1 <> n2)
        | _, _, _ -> failwith "incorrect binop"
      in
      let retv = Direct v in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, retv) eval_session;
      let Var (y, _) = vy in
      let Var (z, _) = vz in
      let y_stk = Fetch.fetch_stk ~eval_session ~stk env vy in
      let z_stk = Fetch.fetch_stk ~eval_session ~stk env vz in
      let y_key = generate_lookup_key y y_stk in
      let z_key = generate_lookup_key z z_stk in
      retv, Session.Concolic.add_formula conc_session @@ Riddler.binop_without_picked x_key op y_key z_key
    | Abort_body -> begin
      (* TODO: concolic -- I think it's done, but leaving this todo just in case *)
      let ab_v = AbortClosure env in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, ab_v) eval_session;
      let conc_session = Session.Concolic.found_abort conc_session in
      match eval_session.mode with
      | Plain -> raise @@ Found_abort (ab_v, conc_session)
      (* next two are for debug mode *)
      | With_target_x target ->
        if Id.equal target x
        then raise @@ Found_target { x ; stk ; v = ab_v }
        else raise @@ Found_abort (ab_v, conc_session)
      | With_full_target (target, tar_stk) ->
        if Id.equal target x && Concrete_stack.equal_flip tar_stk stk
        then raise @@ Found_target { x ; stk ; v = ab_v }
        else raise @@ Found_abort (ab_v, conc_session)
      end
    | Assert_body _ | Assume_body _ ->
      let v = Value_bool true in
      let retv = Direct v in
      Session.Eval.add_val_def_mapping (x, stk) (cbody, retv) eval_session;
      retv, Session.Concolic.add_key_eq_val conc_session x_key v
  in
  Debug.debug_clause ~eval_session x v stk;
  (Ident_map.add x (v, stk) env, v, conc_session)

let eval_exp_default
  ~(eval_session: Session.Eval.t)
  ~(conc_session : Session.Concolic.t)
  (e : expr)
  : Dvalue.denv * Dvalue.t * Session.Concolic.t
  =
  eval_exp
    ~eval_session 
    ~conc_session
    Concrete_stack.empty (* empty stack *)
    Ident_map.empty (* empty environment *)
    e

(*
  -------------------
  BEGIN CONCOLIC EVAL   
  -------------------

  This sections starts up and runs the concolic evaluator (see the eval_exp above)
  repeatedly to hit all the branches.

  This eval spans multiple concolic sessions, trying to hit the branches.
*)
let rec loop (e : expr) (prev_session : Session.t) : unit =
  match Session.next prev_session with
  | `Done session ->
    Format.printf "------------------------------\nFinishing...\n";
    session
    |> Session.finish
    |> Session.print
  | `Next (session, conc_session, eval_session) ->
    Format.printf "------------------------------\nRunning program...\n";
    Session.print session;

    try
      (* might throw exception which is to be caught below *)
      let _, v, conc_session = eval_exp_default ~eval_session ~conc_session e in
      Format.printf "Evaluated to: %a\n" Dvalue.pp v;
      loop e @@ Session.accum_concolic session conc_session
    with
    (* TODO: Error cases: TODO, if we hit abort, re-run if setting is applied. *)
    | Found_abort (_, conc_session) ->
        Format.printf "Running next iteration of concolic after abort\n";
        loop e @@ Session.accum_concolic session conc_session
    | Reach_max_step (x, stk) ->
        (* Fmt.epr "Reach max steps\n" ; *)
        (* alert_lookup target_stk x stk session.lookup_alert; *)
        raise (Reach_max_step (x, stk))
    | Run_the_same_stack_twice (x, stk) ->
        Fmt.epr "Run into the same stack twice\n" ;
        (* Debug.alert_lookup (!session).eval x stk ; *) (* no debug statement because we don't keep the eval session *)
        raise (Run_the_same_stack_twice (x, stk))
    | Run_into_wrong_stack (x, stk) ->
        Fmt.epr "Run into wrong stack\n" ;
        (* Debug.alert_lookup (!session).eval x stk ; *) (* ^^ *)
        raise (Run_into_wrong_stack (x, stk))

(* Concolically execute/test program. *)
let concolic_eval (e : expr) : unit = 
  Format.printf "\nStarting concolic execution...\n";
  Session.load_branches (Session.create_default ()) e
  |> loop e (* Repeatedly evaluate program *)