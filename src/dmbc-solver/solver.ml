open Core
open Z3
module Sym = Dbmc_lib.Symbol

module type Context = sig
  val ctx : Z3.context
end

module Make (C : Context) () = struct
  let ctx = C.ctx

  let _counter = ref 0

  let get_new_sym () = 
    let last = !_counter in 
    let name = "$c" ^ (string_of_int last) in
    Int.incr _counter;
    Symbol.mk_string ctx name
  let intS = Arithmetic.Integer.mk_sort ctx
  let boolS = Boolean.mk_sort ctx

  let strS = Seq.mk_string_sort ctx

  let intC = Datatype.mk_constructor_s ctx "Int"
      (Symbol.mk_string ctx "is-Int") [Symbol.mk_string ctx "i"] [Some intS] [1]
  let boolC = Datatype.mk_constructor_s ctx "Bool"
      (Symbol.mk_string ctx "is-Bool") [Symbol.mk_string ctx "b"] [Some boolS] [1]
  let funC = Datatype.mk_constructor_s ctx "Fun"
      (Symbol.mk_string ctx "is-Fun") [Symbol.mk_string ctx "b"] [Some strS] [1]

  (* let bottomC = Datatype.mk_constructor_s ctx "Bottom"
      (Symbol.mk_string ctx "is-Bottom") [] [] [] *)

  let valS = Datatype.mk_sort_s ctx "IntOrBoolOrFun"
      [intC; boolC; funC]

  let intR, boolR, funR = 
    match Datatype.get_recognizers valS with
    | r1::r2::r3::[] -> r1, r2, r3
    | _ -> failwith "recogniziers mismatch"

  let ifInt e = FuncDecl.apply intR [e]
  let ifBool e = FuncDecl.apply boolR [e]
  let ifFun e = FuncDecl.apply funR [e]


  let getInt, getBool, getFid = 
    match Datatype.get_accessors valS with
    | [a1]::[a2]::[a3]::[] -> a1, a2, a3
    | _ -> failwith "accessors mismatch"
  let intD = Datatype.Constructor.get_constructor_decl intC
  let boolD = Datatype.Constructor.get_constructor_decl boolC
  let funD = Datatype.Constructor.get_constructor_decl funC

  (* let bottomD = Datatype.Constructor.get_constructor_decl bottomC *)

  let int_ i = FuncDecl.apply intD [Arithmetic.Integer.mk_numeral_i ctx i]
  let bool_ b = FuncDecl.apply boolD [Boolean.mk_val ctx b]
  let fun_ s = FuncDecl.apply funD [Seq.mk_string ctx s]
  (* let bottom_ = FuncDecl.apply bottomD [] *)

  let true_ = bool_ true
  let false_ = bool_ false

  module StringSort = struct
    let strS = Z3.Seq.mk_string_sort ctx
    let string_ s = Seq.mk_string ctx s
    let var_ n = Expr.mk_const_s ctx n strS
  end

  let var_ n = Expr.mk_const_s ctx n valS

  let top_stack_name = "!stack"

  let top_stack_var = StringSort.var_ top_stack_name

  let eq e1 e2 = Boolean.mk_eq ctx e1 e2

  let and_ e1 e2 = Boolean.mk_and ctx [e1; e2]

  let join = Boolean.mk_and ctx

  let not_ = Boolean.mk_not ctx

  let bop case inj fn e1 e2 =
    let p1 = FuncDecl.apply case [e1] in
    let p2 = FuncDecl.apply case [e2] in
    let p3 = fn p1 p2 in
    FuncDecl.apply inj [p3]

  let fn_two_ints fop y e1 e2 = 
    let ey = bop getInt intD fop e1 e2 in
    join [eq y ey; ifInt e1; ifInt e2]

  let fn_two_ints_to_bool fop y e1 e2 = 
    let ey = bop getInt boolD fop e1 e2 in
    join [eq y ey; ifInt e1; ifInt e2]

  let fn_two_bools fop y e1 e2 = 
    let ey = bop getBool boolD fop e1 e2 in
    join [eq y ey; ifBool e1; ifBool e2]

  let fn_plus = fn_two_ints (fun e1 e2 -> Arithmetic.mk_add ctx [e1; e2])
  let fn_minus = fn_two_ints (fun e1 e2 -> Arithmetic.mk_sub ctx [e1; e2])
  let fn_times = fn_two_ints (fun e1 e2 -> Arithmetic.mk_mul ctx [e1; e2])
  let fn_divide = fn_two_ints (Arithmetic.mk_div ctx)
  let fn_modulus = fn_two_ints (Arithmetic.Integer.mk_mod ctx)

  let fn_lt = fn_two_ints_to_bool (Arithmetic.mk_lt ctx)
  let fn_le = fn_two_ints_to_bool (Arithmetic.mk_le ctx)
  let fn_eq = fn_two_ints_to_bool (Boolean.mk_eq ctx)

  let fn_and = fn_two_bools and_
  let fn_or = fn_two_bools (fun e1 e2 -> Boolean.mk_or ctx [e1; e2])
  let fn_xor = fn_two_bools (Boolean.mk_xor ctx)

  (* let fn_eq y x1 x2 =
     eq y (eq x1 x2) *)
  let ground_truth = eq true_ true_

  let var_of_symbol sym = 
    sym |> Sym.to_string_mach |> var_

  let name_of_lookup xs stk = 
    match xs with
    | [x] -> Sym.Id(x,stk) |> Sym.to_string_mach
    | _::_ -> (
        let p1 = [%sexp_of: Dbmc_lib.Id.t list] xs |> Sexp.to_string_mach in
        let p2 = Dbmc_lib.Relative_stack.sexp_of_t stk |> Sexp.to_string_mach in
        p1 ^ p2
      )
    | [] -> failwith "name_of_lookup empty"

  open Dbmc_lib
  let rec z3_phis_of_smt_phi = function
    | Constraint.Eq_v (sx, cv) -> 
      let x = var_of_symbol sx in
      let v = match cv with
        | Int i -> int_ i
        | Bool b -> bool_ b
        | Fun fid -> fun_ (fid |> Dbmc_lib.Id.sexp_of_t |> Sexp.to_string_mach)
        | Record -> failwith "no record yet"
      in
      eq x v
    (* [eq x v; not_ (eq x bottom_)] *)
    | Constraint.Eq_x (sx, sy) -> 
      let x = var_of_symbol sx in
      let y = var_of_symbol sy in
      eq x y
    (* [eq x y; not_ (eq x bottom_); not_ (eq y bottom_)] *)
    | Constraint.Eq_binop (sy, sx1, op, sx2) ->
      let y = var_of_symbol sy in
      let x1 = var_of_symbol sx1 in
      let x2 = var_of_symbol sx2 in
      let fop = match op with
        | Add -> fn_plus
        | Sub -> fn_minus
        | Mul -> fn_times
        | Div -> fn_divide
        | Mod -> fn_modulus
        | Le -> fn_le
        | Leq -> fn_lt
        | Eq -> fn_eq
        | And -> fn_and
        | Or -> fn_or
        | Xor -> fn_xor
      in
      fop y x1 x2
    (* [eq y (fop x1 x2); not_ (eq y bottom_); not_ (eq x1 bottom_); not_ (eq x2 bottom_)] *)
    | Constraint.Eq_lookup (xs1, s1, xs2, s2) ->
      let x = var_ @@ name_of_lookup xs1 s1 in
      let y = var_ @@ name_of_lookup xs2 s2 in
      eq x y
    (* [eq x y; not_ (eq x bottom_); not_ (eq y bottom_)] *)
    | Constraint.C_and (c1, c2) ->
      let e1 = z3_phis_of_smt_phi c1 in
      let e2 = z3_phis_of_smt_phi c2 in
      Boolean.mk_and ctx [e1; e2]
    | Constraint.C_exclusive cs ->
      if List.length cs = 1 then
        z3_phis_of_smt_phi (List.hd_exn cs)
      else
        let payloads = List.map cs ~f:z3_phis_of_smt_phi in
        let choice_vars = List.map payloads ~f:(fun _ -> Z3.Boolean.mk_const ctx (get_new_sym ())) in
        let chosen_payloads = List.mapi payloads ~f:(fun ci payload ->
            let ci_var = List.nth_exn choice_vars ci in
            let other_vars = List.filteri choice_vars ~f:(fun i _ -> Int.(ci <> i)) in
            let exclusion = 
              other_vars
              |> Z3.Boolean.mk_or ctx
              |> Z3.Boolean.mk_not ctx
            in
            let payload' = and_ payload exclusion in
            Z3.Boolean.mk_implies ctx ci_var payload'
          ) in
        let must_one_choice = Z3.Boolean.mk_or ctx choice_vars in
        join (must_one_choice::chosen_payloads)
    | Constraint.Target_stack stk
      -> (let open StringSort in
          eq (var_ top_stack_name) (string_ @@ (stk |> Relative_stack.to_string))
         )
    | Constraint.Eq_projection (_, _, _)
      -> failwith "no project yet"

  (* model and solution *)
  let get_int_s model s =
    let x = FuncDecl.apply getInt [var_ s] in
    let r = Option.value_exn (Model.eval model x true) in
    Z3.Arithmetic.Integer.get_big_int r
    |> Big_int_Z.int_of_big_int

  let get_top_stack model =
    let rel_stack_v = Option.value_exn (Model.eval model top_stack_var true) in
    let rel_stack_str = Seq.get_string ctx rel_stack_v in
    print_endline rel_stack_str;
    let rel_stack = Relative_stack.of_string rel_stack_str in
    rel_stack

  let check_and_get_model (solver : Solver.solver) =
    (* Model.model  *)
    match Z3.Solver.check solver [] with
    | Z3.Solver.SATISFIABLE ->
      begin
        match Z3.Solver.get_model solver with
        | None -> 
          print_endline "none";
          None
        | Some model -> 
          print_endline @@ Z3.Model.to_string model;
          Some model
      end
    | Z3.Solver.UNSATISFIABLE ->
      print_endline "UNSAT";
      None
    | Z3.Solver.UNKNOWN ->
      failwith @@ Printf.sprintf "Unknown result in solve: %s"
        (Z3.Solver.get_reason_unknown solver)

end