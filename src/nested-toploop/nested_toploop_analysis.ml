
open Batteries;;
open A_translator;;
open Core_ast;;
open Ddpa_abstract_ast;;

let core_to_nested map core =
  match core with
  | Core_toploop_analysis_types.Application_of_non_function
      (Abs_var v1, Abs_var v2, fv1, fv2) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    Nested_toploop_analysis_types.Application_of_non_function(uid1, uid2, fv1, fv2)
  | Core_toploop_analysis_types.Projection_of_non_record
      (Abs_var v1, Abs_var v2, fv) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    Nested_toploop_analysis_types.Projection_of_non_record(uid1, uid2, fv)
  | Core_toploop_analysis_types.Projection_of_absent_label
      (Abs_var v1, Abs_var v2, fv, i) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    Nested_toploop_analysis_types.Projection_of_absent_label(uid1, uid2, fv, i)
  | Core_toploop_analysis_types.Deref_of_non_ref
      (Abs_var v1, Abs_var v2, fv) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    Nested_toploop_analysis_types.Deref_of_non_ref(uid1, uid2, fv)
  | Core_toploop_analysis_types.Update_of_non_ref
      (Abs_var v1, Abs_var v2, fv) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    Nested_toploop_analysis_types.Update_of_non_ref(uid1, uid2, fv)
  | Core_toploop_analysis_types.Invalid_binary_operation
      (Abs_var v1, op, Abs_var v2, fv1, Abs_var v3, fv2) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    let Proof_rule(_, uid3) = Ident_map.find v3 map in
    Nested_toploop_analysis_types.Invalid_binary_operation(uid1, op, uid2, fv1, uid3, fv2)
  | Core_toploop_analysis_types.Invalid_unary_operation
      (Abs_var v1, op, Abs_var v2, fv) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    Nested_toploop_analysis_types.Invalid_unary_operation(uid1, op, uid2, fv)
  | Core_toploop_analysis_types.Invalid_indexing_subject
      (Abs_var v1, Abs_var v2, fv) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    Nested_toploop_analysis_types.Invalid_indexing_subject(uid1, uid2, fv)
  | Core_toploop_analysis_types.Invalid_indexing_argument
      (Abs_var v1, Abs_var v2, fv) ->
    let Proof_rule(_, uid1) = Ident_map.find v1 map in
    let Proof_rule(_, uid2) = Ident_map.find v2 map in
    Nested_toploop_analysis_types.Invalid_indexing_argument(uid1, uid2, fv)
;;

let batch_translation map cores =
  Enum.map (core_to_nested map) cores
;;
