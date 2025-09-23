open Core

let parse = Lang.Parse.parse_program_to_json
let decode src = parse src |> Yojson.Safe.from_string

let stmt_fields = function
  | `Assoc f -> f
  | _ -> Alcotest.fail "expected object"

let field k f = List.Assoc.find_exn ~equal:String.equal f k

let expect_stmt ~index ~ids f =
  let open Alcotest in
  check int "index" index
    (match field "index" f with
    | `Int i -> i
    | v -> failf "index not int: %s" (Yojson.Safe.to_string v)) ;
  check (list string) "ids" ids
    (match field "ids" f with
    | `List ls ->
        List.map ls ~f:(function
          | `String s -> s
          | v -> failf "id not string: %s" (Yojson.Safe.to_string v))
    | v -> failf "ids not list: %s" (Yojson.Safe.to_string v))

let test_case_simple () =
  match decode "let x = 1\n" with
  | `List [a] -> expect_stmt ~index:0 ~ids:["x"] (stmt_fields a)
  | _ -> Alcotest.fail "unexpected JSON"

let test_case_multi () =
  match decode "let x = 1\nlet y = 2\n" with
  | `List [a; b] ->
      expect_stmt ~index:0 ~ids:["x"] (stmt_fields a);
      expect_stmt ~index:1 ~ids:["y"] (stmt_fields b)
  | _ -> Alcotest.fail "unexpected JSON"

let () =
  Alcotest.run "parse-bluejay" [
    "json", [
      Alcotest.test_case "simple" `Quick test_case_simple;
      Alcotest.test_case "multi"  `Quick test_case_multi;
    ]
  ]