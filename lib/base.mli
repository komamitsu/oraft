type mode = FOLLOWER | CANDIDATE | LEADER

val show_mode : mode -> string

type node = { id : int; host : string; port : int; }

val pp_node : Format.formatter -> node -> unit

val show_node : node -> string

val node_to_yojson : node -> Yojson.Safe.t

val node_of_yojson :
  Yojson.Safe.t -> node Ppx_deriving_yojson_runtime.error_or

val node_of_yojson_exn : Yojson.Safe.t -> node
