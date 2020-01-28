open Lwt
open Base
open State

type t = {
  conf : Conf.t;
  process : unit Lwt.t;
  post_command : string -> bool Lwt.t;
}

let start conf_file ~apply_log =
  let conf = Conf.from_file conf_file in
  let lock = Lock.create () in
  let state =
    {
      persistent_state = PersistentState.load conf.state_dir;
      persistent_log = PersistentLog.load conf.state_dir;
      volatile_state = VolatileState.create ();
    }
  in
  let rec process state_exec : unit Lwt.t =
    state_exec () >>= fun next ->
    let next_state_exec =
      match next with
      | FOLLOWER -> Follower.run (Follower.init ~conf ~lock ~apply_log ~state)
      | CANDIDATE ->
          Candidate.run (Candidate.init ~conf ~lock ~apply_log ~state)
      | LEADER -> Leader.run (Leader.init ~conf ~lock ~apply_log ~state)
    in
    process next_state_exec
  in
  let client_logger =
    Logger.create conf.node_id None conf.log_file conf.log_level
  in
  let post_command s =
    let request_json =
      let r : Params.client_command_request = { data = s } in
      Params.client_command_request_to_yojson r
    in
    let request =
      Request_sender.post ~node_id:conf.node_id ~logger:client_logger
        ~url_path:"client_command" ~request_json
        ~converter:(fun response_json ->
          match Params.client_command_response_of_yojson response_json with
          | Ok param -> Ok (Params.CLIENT_COMMAND_RESPONSE param)
          | Error _ as err -> err)
    in
    match PersistentState.voted_for state.persistent_state with
    | Some node_id ->
        let current_leader_node = Conf.peer_node conf node_id in
        request current_leader_node >>= fun result ->
        Lwt.return
          ( match result with
          | Some (Params.CLIENT_COMMAND_RESPONSE x) -> x.success
          | Some _ ->
              Logger.error client_logger "Shouldn't reach here";
              false
          | None -> false )
    | None -> Lwt.return false
  in
  {
    conf;
    process =
      process (Follower.run (Follower.init ~conf ~lock ~apply_log ~state));
    post_command;
  }
