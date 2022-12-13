open Core

type mode = Jayil | Jay | Bluejay [@@deriving show]

type t = {
  (* basic *)
  filename : Filename.t; [@printer String.pp]
  sato_mode : mode;
  (* analysis *)
  ddpa_c_stk : Dj_common.Global_config.ddpa_c_stk;
  (* tuning *)
  do_wrap : bool;
  do_instrument : bool;
  run_max_step : int option;
  timeout : Time.Span.t option;
}
[@@deriving show]

let default_ddpa_c_stk = Dj_common.Global_config.C_1ddpa

let default_config =
  {
    filename = "";
    sato_mode = Jayil;
    ddpa_c_stk = default_ddpa_c_stk;
    do_wrap = true;
    do_instrument = true;
    timeout = None (* Time.Span.of_int_sec 60 *);
    run_max_step = None;
  }