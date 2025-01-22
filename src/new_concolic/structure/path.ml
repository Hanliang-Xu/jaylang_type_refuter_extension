
(*
  A path is a sequence of nodes in a tree. The only thing that really matters is the direction of branches taken.
*)

open Core

module T = struct
  (* Branches at the top of the tree are first *)
  type t = { forward_path : Direction.Packed.t list }
    [@@unboxed][@@deriving compare]
end

include T

module Reverse =
struct
  (* Branches at the front are the leaves of the tree *)
  type t = { backward_path : Direction.Packed.t list }
    [@@unboxed][@@deriving compare]

  let empty : t = { backward_path = [] }

  let return ls = { backward_path = ls }

  let cons front path =
    return
    @@ front :: path.backward_path

  let concat path1 path2 = 
    return 
    @@ path1.backward_path @ path2.backward_path

  let drop_hd_exn path =
    return
    @@ List.tl_exn path.backward_path

  let to_forward_path x =
    { forward_path = List.rev x.backward_path }
  
end