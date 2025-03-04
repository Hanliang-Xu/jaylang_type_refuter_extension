
open Core

type 'a t = Equality of ('a Expression.t * 'a Direction.t) [@@unboxed]

let to_expression (type a) (Equality (expr, dir) : a t) : bool Expression.t =
  let eq_int a b = Expression.op a b Expression.Typed_binop.Equal_int in
  match dir with
  | True_direction -> expr 
  | False_direction -> Expression.not_ expr
  | Case_int i -> eq_int expr (Expression.const_int i)
  | Case_default { not_in } ->
    List.fold not_in ~init:Expression.true_ ~f:(fun acc i ->
      let neq = Expression.op expr (Expression.const_int i) Expression.Typed_binop.Not_equal in
      Expression.op acc neq Expression.Typed_binop.And
    )

let flip (Equality (e, dir) : bool t) : bool t =
  match dir with
  | True_direction -> Equality (e, False_direction)
  | False_direction -> Equality (e, True_direction)

let direction (type a) (Equality (_, dir) : a t) : a Direction.t =
  dir
