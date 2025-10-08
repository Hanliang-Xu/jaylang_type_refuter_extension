open Core

let parse = Lang.Parser.parse_program_to_json
let decode src = parse src |> Yojson.Safe.from_string

let stmt_fields = function
  | `Assoc f -> f
  | _ -> Alcotest.fail "expected object"

let field k f = List.Assoc.find_exn ~equal:String.equal f k

let pos_of k f =
  match field k f with
  | `Assoc ps ->
      let i key =
        match List.Assoc.find_exn ~equal:String.equal ps key with
        | `Int v -> v
        | v -> failwith (Yojson.Safe.to_string v)
      in
      (i "line", i "col")
  | v -> failwith (Yojson.Safe.to_string v)

let expect_stmt ?start ?end_ ~index ~ids f =
  let open Alcotest in
  check int "index" index
    (match field "index" f with
    | `Int i -> i
    | v -> failwith (Yojson.Safe.to_string v)) ;
  check (list string) "ids" ids
    (match field "ids" f with
    | `List ls ->
        List.map
          ~f:(function
            | `String s -> s | v -> failwith (Yojson.Safe.to_string v))
          ls
    | v -> failwith (Yojson.Safe.to_string v)) ;
  Option.iter start ~f:(fun (l, c) ->
      let l', c' = pos_of "start" f in
      check int "start line" l l' ;
      check int "start col" c c') ;
  Option.iter end_ ~f:(fun (l, c) ->
      let l', c' = pos_of "end" f in
      check int "end line" l l' ;
      check int "end col" c c')

let test_case_simple () =
  match decode "let x = 1\n" with
  | `List [a] ->
      expect_stmt ~index:0 ~ids:["x"] ~start:(1,0) ~end_:(1,9) (stmt_fields a)
  | _ -> Alcotest.fail "unexpected JSON"

let test_case_multi () =
  let src = "let x = 1 let y = 2\nlet z = 3" in
  match decode src with
  | `List [a; b; c] ->
      expect_stmt ~index:0 ~ids:["x"] ~start:(1,0)  (stmt_fields a);
      expect_stmt ~index:1 ~ids:["y"] ~start:(1,10) (stmt_fields b);
      expect_stmt ~index:2 ~ids:["z"] ~start:(2,0)  (stmt_fields c)
  | _ -> Alcotest.fail "unexpected JSON"

let () =
  Alcotest.run "parse-bluejay"
    [
      ( "json",
        [
          Alcotest.test_case "simple" `Quick test_case_simple;
          Alcotest.test_case "multi" `Quick test_case_multi;
        ] );
    ]
