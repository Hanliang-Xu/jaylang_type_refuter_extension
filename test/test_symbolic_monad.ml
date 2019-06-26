(** This module contains tests for the solver interface in the symbolic
    interpreter. *)

open Batteries;;
open Jhupllib;;
open OUnit2;;

open Odefa_symbolic_interpreter;;

module F = Formula_test_utils;;

(* **** Scaffolding ***** *)

let _tests_acc = ref [];;
let _add_test name testfn = _tests_acc := (name >:: testfn) :: !_tests_acc;;

(* Experimental monad *)

module Cache_key = struct
  type 'a t = K : int -> unit t;;
  let compare (type a b) (x : a t) (y : b t) : (a,b) Gmap.Order.t =
    let K(x) = x in
    let K(y) = y in
    if x < y then Gmap.Order.Lt else
    if x > y then Gmap.Order.Gt else
      Gmap.Order.Eq
  ;;
end;;

module Spec = struct
  module Cache_key = Cache_key;;
  module Work_collection = Symbolic_monad.QueueWorkCollection;;
end;;

module M = Symbolic_monad.Make(Spec);;

open M;;

(* **** Utils **** *)

type 'a test_result =
  { tr_value : 'a;
    tr_formulae : Formulae.t;
    tr_total_steps : int;
    tr_result_steps : int;
  }
;;

let complete (x : 'a m) : 'a test_result Enum.t =
  let rec loop evaluation steps_so_far : 'a test_result Enum.t =
    let results, evaluation' = step evaluation in
    let new_steps_so_far = steps_so_far + 1 in
    let tagged_results =
      results
      |> Enum.map
        (fun er ->
           { tr_value = er.er_value;
             tr_formulae = er.er_formulae;
             tr_total_steps = new_steps_so_far;
             tr_result_steps = er.er_result_steps;
           }
        )
    in
    Enum.append tagged_results @@
    if is_complete evaluation' then Enum.empty () else
      loop evaluation' new_steps_so_far
  in
  loop (start x) 0
;;

let test_complete_values
    (type a)
    (printer : a Pp_utils.pretty_printer)
    (equal : a -> a -> bool)
    (computation : a m)
    (expected : a list) : unit =
  let results : a test_result Enum.t = complete computation in
  let actual : a list =
    List.of_enum @@ Enum.map (fun tr -> tr.tr_value) results
  in
  assert_equal
    ~printer:(Pp_utils.pp_to_string @@ Pp_utils.pp_list printer)
    ~cmp:(List.eq equal)
    expected
    actual
;;

let test_complete_values_with_steps
    (type a)
    (printer : a Pp_utils.pretty_printer)
    (equal : a -> a -> bool)
    (computation : a m)
    (expected : (a * int) list) : unit =
  let results : a test_result Enum.t = complete computation in
  let actual : (a * int) list =
    List.of_enum @@
    Enum.map (fun tr -> (tr.tr_value,tr.tr_result_steps)) results
  in
  assert_equal
    ~printer:(Pp_utils.pp_to_string @@
              Pp_utils.pp_list @@ Pp_utils.pp_tuple printer Format.pp_print_int)
    ~cmp:(List.eq (fun (x,y) (x',y') -> equal x x' && y = y'))
    expected
    actual
;;

(* **** Tests **** *)

_add_test "pure 4" @@ fun _ ->
let computation =
  return 4
in
test_complete_values_with_steps Format.pp_print_int (=) computation
  [(4,1)]
;;

_add_test "nondeterminism" @@ fun _ ->
let computation =
  let%bind z = pick @@ List.enum [1;2;3;4] in
  return z
in
test_complete_values_with_steps Format.pp_print_int (=) computation
  [(1,1); (2,1); (3,1); (4,1)]
;;

_add_test "nondeterminism and state" @@ fun _ ->
let computation =
  check_formulae @@
  let%bind () = record_formula @@ F.set_int F.x 2 in
  let%bind () = record_formula @@ F.alias F.x F.y in
  let%bind n = pick @@ List.enum [1;2;3] in
  let%bind () = record_formula @@ F.set_int F.y n in
  return n
in
test_complete_values_with_steps Format.pp_print_int (=) computation
  [(2,1)]
;;

_add_test "single pause" @@ fun _ ->
let computation =
  let%bind () = pause () in
  return 5
in
test_complete_values_with_steps Format.pp_print_int (=) computation
  [(5,2)]
;;

_add_test "pause in nondeterminism" @@ fun _ ->
let computation =
  let%bind n = pick @@ List.enum [1;2;3] in
  let%bind () = pause () in
  return n
in
test_complete_values_with_steps Format.pp_print_int (=) computation
  [(1,2); (2,2); (3,2)]
;;

_add_test "nondeterministic pause" @@ fun _ ->
let computation =
  let%bind n = pick @@ List.enum [1;2;3;4;5] in
  let%bind () = if n mod 2 = 0 then pause () else return () in
  return n
in
test_complete_values_with_steps Format.pp_print_int (=) computation
  [(1,1); (3,1); (5,1); (2,2); (4,2)]
;;

(* **** Packaging up tests for main test module ***** *)

let tests = "symbolic monad tests" >::: List.rev !_tests_acc;;
