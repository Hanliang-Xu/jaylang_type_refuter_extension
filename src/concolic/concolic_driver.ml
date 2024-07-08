open Core
open Dbmc
open Dj_common

module CLog = Dj_common.Log.Export.CLog

      
module Test_result =
  struct
    type t =
      | Found_abort of Branch.t * Jil_input.t list (* Found an abort at this branch using these inputs *)
      | Type_mismatch of Jayil.Ast.Ident_new.t * Jil_input.t list (* Proposed addition for removing instrumentation *)
      | Exhausted               (* Ran all possible tree paths, and no paths were too deep *)
      | Exhausted_pruned_tree   (* Ran all possible tree paths up to the given max step *)
      | Timeout                 (* total evaluation timeout *)

    let merge a b =
      match a, b with
      (* When abort and type mismatch are found, we can conclusively end *)
      | (Found_abort _ as x), _ | _, (Found_abort _ as x)
      | (Type_mismatch _ as x), _ | _, (Type_mismatch _ as x) -> x
      (* For the following results, we want to keep the one with the least information to be conservative *)
      | Timeout, _ | _, Timeout -> Timeout
      | Exhausted_pruned_tree,_  | _, Exhausted_pruned_tree -> Exhausted_pruned_tree
      | Exhausted, Exhausted -> Exhausted

    let default : t = Exhausted (* has the least information *)
  end

(*
  ----------------------
  TESTING BY EXPRESSIONS   
  ----------------------
*)

let[@landmark] lwt_test_one : (Jayil.Ast.expr -> Test_result.t Lwt.t) Concolic_options.Fun.t =
  let open Lwt.Infix in
  Concolic_options.Fun.make
  @@ fun (r : Concolic_options.t) ->
      fun (e : Jayil.Ast.expr) ->
        let t0 = Caml_unix.gettimeofday () in
        Concolic_options.Fun.appl Concolic_eval.lwt_eval r e
        >|= function res, has_pruned ->
          CLog.app (fun m -> m "\nFinished concolic evaluation in %fs.\n" (Caml_unix.gettimeofday () -. t0));
          Branch_info.find res ~f:(fun _ -> function Branch_info.Status.Found_abort _ | Type_mismatch _ -> true | _ -> false)
          |> begin function
            | Some (Branch.Or_global.Branch branch, Branch_info.Status.Found_abort inputs) -> Test_result.Found_abort (branch, List.rev inputs)
            | Some (_, Branch_info.Status.Type_mismatch (id, inputs)) -> Test_result.Type_mismatch (id, List.rev inputs)
            | None when not has_pruned -> Exhausted
            | None -> Exhausted_pruned_tree
            | _ -> failwith "impossible abort in global branch"
            end
        
(* [test_incremental n] incrementally increases the max tree depth in [n] equal steps until it reaches the given max depth *)
let[@landmark] test_incremental n : (Jayil.Ast.expr -> Test_result.t Lwt.t) Concolic_options.Fun.t =
  let open Lwt.Infix in
  Concolic_options.Fun.make
  @@ fun (r : Concolic_options.t) ->
      fun (e : Jayil.Ast.expr) ->
        Lwt_unix.with_timeout r.global_timeout_sec
        @@ fun () ->
          n
          |> List.init ~f:(fun i -> (i + 1) * r.max_tree_depth / n)
          |> List.fold
            ~init:(Lwt.return Test_result.default)
            ~f:(fun acc d ->
                acc
                >>= function
                  | Test_result.Found_abort _ | Type_mismatch _ | Timeout -> acc
                  | acc -> begin
                    Concolic_options.Fun.appl lwt_test_one { r with max_tree_depth = d } e
                    >|= Test_result.merge acc
                  end
              )

(* runs [test_incremental 5] and catches lwt timeout *)
let test_with_timeout : (Jayil.Ast.expr -> Test_result.t) Concolic_options.Fun.t =
  Concolic_options.Fun.make
  @@ fun (r : Concolic_options.t) ->
      fun (e : Jayil.Ast.expr) ->
        try
          Lwt_main.run
          @@ Concolic_options.Fun.appl (test_incremental 5) r e
        with
        | Lwt_unix.Timeout ->
          CLog.app (fun m -> m "Quit due to total run timeout in %0.3f seconds.\n" r.global_timeout_sec);
          Test_result.Timeout

let[@landmark] test_expr : (Jayil.Ast.expr -> Test_result.t) Concolic_options.Fun.t =
  Concolic_options.Fun.map
    test_with_timeout
    (fun r ->
      begin
      match r with
      | Test_result.Found_abort _ -> Format.printf "\nFOUND_ABORT\n"
      | Type_mismatch _ ->           Format.printf "\nTYPE_MISMATCH\n"
      | Exhausted ->                 Format.printf "\nEXHAUSTED\n"
      | Exhausted_pruned_tree ->     Format.printf "\nEXHAUSTED_PRUNED_TREE\n"
      | Timeout ->                   Format.printf "\nTIMEOUT\n"
      end;
      r
    )


(*
  -------------------
  TESTING BY FILENAME
  -------------------
*)

let test_jil : (string -> Test_result.t) Concolic_options.Fun.t =
  let open Concolic_options.Fun in
  test_expr
  @. Dj_common.File_utils.read_source

let test_bjy : (string -> Test_result.t) Concolic_options.Fun.t =
  let open Concolic_options.Fun in
  test_expr
  @. (fun filename ->
    filename
    |> Dj_common.File_utils.read_source_full ~do_instrument:false ~do_wrap:true
    |> Dj_common.Convert.jil_ast_of_convert)

let test : (string -> Test_result.t) Concolic_options.Fun.t =
  Concolic_options.Fun.make
  @@ fun r ->
      fun filename ->
      match Core.Filename.split_extension filename with 
      | _, Some "jil" -> Concolic_options.Fun.appl test_jil r filename
      | _, Some "bjy" -> Concolic_options.Fun.appl test_bjy r filename
      | _ -> failwith "expected jil or bjy file"