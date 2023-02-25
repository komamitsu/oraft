open Stdio.Out_channel

type level = TRACE | DEBUG | INFO | WARN | ERROR

type t = {
  node_id : int;
  mode : Base.mode option;
  output_path : string option;
  level : level;
}

let int_of_level = function
  | TRACE -> 0
  | DEBUG -> 1
  | INFO -> 2
  | WARN -> 3
  | ERROR -> 4


let string_of_level = function
  | TRACE -> "TRACE"
  | DEBUG -> "DEBUG"
  | INFO -> "INFO"
  | WARN -> "WARN"
  | ERROR -> "ERROR"


let level_of_string s =
  match s with
  | "TRACE" -> TRACE
  | "DEBUG" -> DEBUG
  | "INFO" -> INFO
  | "WARN" -> WARN
  | "ERROR" -> ERROR
  | _ -> failwith (Printf.sprintf "Unexpected value: %s" s)


let create ~node_id ?mode ?output_path ~level () =
  { node_id; mode; output_path; level = level_of_string level }


let write t ~level ~msg =
  let mode =
    match t.mode with Some x -> Base.show_mode x | None -> "--------"
  in
  if int_of_level level >= int_of_level t.level
  then
    let now = Core.Time_ns.to_string_iso8601_basic (Core.Time_ns.now ()) ~zone:Core.Time.Zone.utc in
    let msg = Str.(global_replace (regexp "\n") "" msg) in
    let s =
      Printf.sprintf "%s %s [%d:%s] - %s\n" now (string_of_level level)
        t.node_id mode msg
    in
    match t.output_path with
      | Some output_path -> (
        with_file output_path
          ~f:(fun file ->
            ignore (output_string file s))
          ~append:true
      )
      | None -> print_endline s


let debug t msg = write t ~level:DEBUG ~msg

let info t msg = write t ~level:INFO ~msg

let warn t msg = write t ~level:WARN ~msg

let error t msg = write t ~level:ERROR ~msg
