(
  ; all good
  (
    (r (Hit) (Hit))
    (call_fun_branch (Hit) (Hit))
    (sum_val_is_desired_branch (Hit) (Hit))
  )
  ; solver times out when solving
  (
    (r (Hit) (Hit))
    (call_fun_branch (Hit) (Hit))
    (sum_val_is_desired_branch (Unknown 0) (Hit))
  )
  ; reaches max step too many times
  (
    (r (Hit) (Reach_max_step 0))
    (call_fun_branch (Hit) (Hit))
    (sum_val_is_desired_branch Unreachable_because_max_step (Hit))
  )
  (
    (r (Hit) (Reach_max_step 0))
    (call_fun_branch (Hit) (Hit))
    (sum_val_is_desired_branch (Unknown 0) (Hit))
  )
)