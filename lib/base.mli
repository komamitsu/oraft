type mode = FOLLOWER | CANDIDATE | LEADER

val pp_mode : Format.formatter -> mode -> unit

val show_mode : mode -> string

type node = { id : int; host : string; port : int; app_port : int }

val pp_node : Format.formatter -> node -> unit

val show_node : node -> string

val node_to_yojson : node -> Yojson.Safe.t

val node_of_yojson : Yojson.Safe.t -> node Ppx_deriving_yojson_runtime.error_or

val node_of_yojson_exn : Yojson.Safe.t -> node

type apply_log = node_id:int -> log_index:int -> log_data:string -> unit
