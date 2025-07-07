
open Core

module T = struct
  type t =
    | Timestamp of int Preface.Nonempty_list.t [@@unboxed]
end

include T

let empty = Timestamp (Last 1)

let push (Timestamp ls) = Timestamp (1 :: ls)

let increment = function
  | Timestamp Last i -> Timestamp (Last (i + 1))
  | Timestamp (hd :: tl) -> Timestamp (hd + 1 :: tl)

let compare (Timestamp a) (Timestamp b) =
  let rec back_to_front (l : 'a Preface.Nonempty_list.t) : 'a Seq.t =
    match l with
    | Last x -> Seq.return x
    | x :: xs -> Seq.append (back_to_front xs) (Seq.return x)
  in
  Seq.compare Int.compare (back_to_front a) (back_to_front b)

module Map = Baby.W.Map.Make (struct
  type t = T.t
  let compare = compare
end)
