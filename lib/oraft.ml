open Lwt
open Base
open State

type t = {
  conf : Conf.t;
  process : unit Lwt.t;
  post_command : string -> bool Lwt.t;
}

let state (conf: Conf.t) =
  {
    persistent_state = PersistentState.load ~state_dir:conf.state_dir;
    persistent_log = PersistentLog.load ~state_dir:conf.state_dir;
    volatile_state = VolatileState.create ();
  }

let process ~conf ~apply_log ~state ~state_exec : unit Lwt.t =
  let rec loop state_exec =
    state_exec () >>= fun next ->
    let next_state_exec =
      match next with
      | FOLLOWER -> Follower.run (Follower.init ~conf ~apply_log ~state)
      | CANDIDATE ->
          Candidate.run (Candidate.init ~conf ~apply_log ~state)
      | LEADER -> Leader.run (Leader.init ~conf ~apply_log ~state)
    in
    loop next_state_exec
  in
  loop state_exec

let post_command ~(conf:Conf.t) ~logger ~state s =
  let request_json =
    let r : Params.client_command_request = { data = s } in
    Params.client_command_request_to_yojson r
  in
  let request =
    Request_sender.post ~node_id:conf.node_id ~logger
      ~url_path:"client_command" ~request_json
      ~converter:(fun response_json ->
        match Params.client_command_response_of_yojson response_json with
        | Ok param -> Ok (Params.CLIENT_COMMAND_RESPONSE param)
        | Error _ as err -> err)
  in
  match PersistentState.voted_for state.persistent_state with
  | Some node_id ->
      let current_leader_node = Conf.peer_node conf ~node_id:node_id in
      request current_leader_node >>= fun result ->
      Lwt.return
        ( match result with
        | Some (Params.CLIENT_COMMAND_RESPONSE x) -> x.success
        | Some _ ->
            Logger.error logger "Shouldn't reach here";
            false
        | None -> false )
  | None -> Lwt.return false

let start ~conf_file ~apply_log =
  let conf = Conf.from_file conf_file in
  let state = state conf in
  let logger = Logger.create ~node_id:conf.node_id ~mode:None ~output_path:conf.log_file ~level:conf.log_level in
  let post_command = post_command ~conf ~logger ~state in
  let initial_state_exec = Follower.run (Follower.init ~conf ~apply_log ~state) in
  {
    conf;
    process = process ~conf ~apply_log ~state ~state_exec:initial_state_exec;
    post_command;
  }
