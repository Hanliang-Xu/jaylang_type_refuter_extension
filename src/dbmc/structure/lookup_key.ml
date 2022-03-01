open Core

module T = struct
  type t = { x : Id.t; xs : Lookup_stack.t; r_stk : Rstack.t }
  [@@deriving sexp_of, compare, equal, hash]
end

include T
include Comparator.Make (T)

let start (x : Id.t) : t = { x; xs = []; r_stk = Rstack.empty }
let of_parts x xs r_stk = { x; xs; r_stk }
let of_parts2 xs r_stk = { x = List.hd_exn xs; xs = List.tl_exn xs; r_stk }
let to_parts key = (key.x, key.xs, key.r_stk)
let to_parts2 key = (key.x :: key.xs, key.r_stk)
let to_first key x = { key with x; xs = [] }
let replace_x key x = { key with x }
let replace_x2 key (xr, lbl) = { key with x = xr; xs = lbl :: key.xs }
let drop_x key = { key with x = List.hd_exn key.xs; xs = List.tl_exn key.xs }
let drop_xs key = { key with xs = [] }
let lookups key = key.x :: key.xs

let to_string key =
  Printf.sprintf "%s_%s"
    (Lookup_stack.to_string (lookups key))
    (Rstack.to_string key.r_stk)

let pp oc key =
  Fmt.pf oc "%s[%a]" (Lookup_stack.to_string (lookups key)) Rstack.pp key.r_stk

let parts_to_str x xs r_stk = to_string (of_parts x xs r_stk)
let parts2_to_str xs r_stk = to_string (of_parts2 xs r_stk)

let chrono_compare map k1 k2 =
  let x1, xs1, r_stk1 = to_parts k1 in
  let x2, xs2, r_stk2 = to_parts k2 in
  assert (List.is_empty xs1);
  assert (List.is_empty xs2);
  let rec compare_stack s1 s2 =
    match (s1, s2) with
    | [], [] ->
        if Id.equal x1 x2
        then 0
        else if Tracelet.is_before map x1 x2
        then 1
        else -1
    | (cs1, f1) :: ss1, (cs2, f2) :: ss2 ->
        if Rstack.equal_frame (cs1, f1) (cs2, f2)
        then compare_stack ss1 ss2
        else if Id.equal cs1 cs2
        then failwith "the same promgram points"
        else if Tracelet.is_before map cs1 cs2
        then 1
        else -1
    | _, _ -> 1
  in
  let stk1, co_stk1 = Rstack.construct_stks r_stk1 in
  let stk2, co_stk2 = Rstack.construct_stks r_stk2 in
  let result_co_stk = compare_stack co_stk1 co_stk2 in
  if result_co_stk = 0 then compare_stack stk1 stk2 else result_co_stk

let get_f_return map fid r_stk x xs =
  let fblock = Odefa_ast.Ast.Ident_map.find fid map in
  let x' = Tracelet.ret_of fblock in
  let r_stk' = Rstack.push r_stk (x, fid) in
  let key_x_ret = of_parts x' xs r_stk' in
  key_x_ret
