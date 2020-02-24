open Core
open Base

type t = {
  node_id : int;
  nodes : node list;
  state_dir : string;
  log_file : string;
  log_level : string;
  election_timeout_millis : int;
  heartbeat_interval_millis : int;
  request_timeout_millis : int;
}
[@@deriving show, yojson]

let from_file file : t =
  let json = Yojson.Safe.from_file file in
  match of_yojson json with
  | Ok t ->
      Unix.mkdir_p t.state_dir;
      Unix.mkdir_p (Filename.dirname t.log_file);
      t
  | Error err -> failwith (Printf.sprintf "Failed to parse JSON: %s" err)


let my_node t = List.find_exn t.nodes ~f:(fun node -> node.id = t.node_id)

let peer_node t ~node_id =
  List.find_exn t.nodes ~f:(fun node -> node.id = node_id)


let peer_nodes t = List.filter t.nodes ~f:(fun node -> node.id <> t.node_id)

let majority_of_nodes t =
  List.length t.nodes |> float_of_int |> fun x ->
  x /. 2.0 |> Float.round_up |> int_of_float
