(** This module contains tests for the solver interface in the symbolic
    interpreter. *)

open Batteries;;
open OUnit2;;

module F = Formula_test_utils;;

let _tests_acc = ref [];;
let _add_test name testfn = _tests_acc := (name >:: testfn) :: !_tests_acc;;

_add_test "simple solvable" @@ fun _ ->
F.assert_solvable
  [ F.alias F.x F.y;
    F.set_int F.x 5;
  ]
;;

_add_test "simple unsolvable" @@ fun _ ->
F.assert_unsolvable
  [ F.alias F.x F.y;
    F.set_int F.x 5;
    F.set_int F.y 6;
  ]
;;

_add_test "solvable transitivity" @@ fun _ ->
F.assert_solvable
  [ F.alias F.x F.y;
    F.alias F.y F.z;
    F.set_int F.x 5;
    F.set_int F.z 5;
  ]
;;

_add_test "unsolvable transitivity" @@ fun _ ->
F.assert_unsolvable
  [ F.alias F.x F.y;
    F.alias F.y F.z;
    F.set_int F.x 5;
    F.set_int F.z 6;
  ]
;;

_add_test "variables distinguished by stack" @@ fun _ ->
F.assert_solvable
  [ F.set_int F.x 5;
    F.set_int F.xa 8;
  ]
;;

_add_test "immediate type error: int,bool" @@ fun _ ->
F.assert_symbol_type_error
  [ F.set_int F.x 5;
    F.set_bool F.y true;
    F.alias F.x F.y;
  ]
;;

let tests = "solver tests" >::: List.rev !_tests_acc;;
