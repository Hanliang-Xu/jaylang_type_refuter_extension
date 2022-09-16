(
  ; higher-order bmc
  ; no better than forward

  ; smbc
  ; vendor/smbc_data/_opam/bin/smbc benchmark/cases/smbc/fold/fold0.smt2

  ; higher-order runtime contract
  ; 

  ; rosette

  (testcases_to_time (
    ; recursive flip a boolean
    ; "input_blur.jay"

    ; the sum of two products
    ; "facehugger.jay"

    ; "list_flatten.jay"

    ; "ddse/k_cfa_2.jay"
    ; "k_cfa_3.jay"
    ; "input_map.jay"
    ; "input_mj09.jay"
    ; "input_sat_1.jay"
    ; "input_sat_1_direct.jay"
    ; "smbc_fold0s.jay"
    ; "smbc_gen_list_len.jay"
    ; "smbc_long_rev_sum3.jay"
    ; "smbc_pigeon.jay"
    ; "smbc_sorted_sum.jay"

    ;;  
    ;; "input_eta.jay"

    "smbc/fold/fold0.jay"

    ; need to encode uninterpreted function
    ;"smbc/fold/fold1s.jay"

    ; slow to encode encode the `eval`
    ; "smbc/expr/expr0.jay"

    ; see _buggy_list_append.jay first
    ; long_rev_sum3.jay

    ; smbc/pigeon/pigeon4.jay

    ; now for hopv/mochi
    ;"mochi/mochi/ack.jay"
    
    ; slow
    ;"mochi/mochi/array_init.jay"

    
    )
  )
  (testcases_not_time (
    ; "input_list_sum_add_build.jay"
    )
  )
  (test_path "benchmark/cases")
  (repeat 1)
  (timeout "20m")
)
