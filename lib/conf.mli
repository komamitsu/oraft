type t = {
  node_id : int;
  nodes : Base.node list;
  state_dir : string;
  log_file : string;
  log_level : string;
  election_timeout_millis : int;
  heartbeat_interval_millis : int;
  request_timeout_millis : int;
}

val show : t -> string

val to_yojson : t -> Yojson.Safe.t

val of_yojson : Yojson.Safe.t -> t Ppx_deriving_yojson_runtime.error_or

val from_file : string -> t

val my_node : t -> Base.node

val peer_node : t -> node_id:int -> Base.node

val peer_nodes : t -> Base.node list

val majority_of_nodes : t -> int
