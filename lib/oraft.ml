open Lwt
open Base
open State

type leader_node = { host : string; port : int }

type current_state = { mode : mode; term : int; leader : leader_node option }

type t = {
  conf : Conf.t;
  process : unit Lwt.t;
  post_command : string -> bool Lwt.t;
  current_state : unit -> current_state;
}

let state (conf : Conf.t) =
  {
    persistent_state = PersistentState.load ~state_dir:conf.state_dir;
    persistent_log = PersistentLog.load ~state_dir:conf.state_dir;
    volatile_state = VolatileState.create ();
  }


let process ~conf ~logger ~apply_log ~state ~state_exec : unit Lwt.t =
  let rec loop state_exec =
    state_exec () >>= fun next ->
    let next_state_exec =
      VolatileState.update_mode state.volatile_state ~logger next;
      match next with
      | FOLLOWER -> Follower.run (Follower.init ~conf ~apply_log ~state)
      | CANDIDATE -> Candidate.run (Candidate.init ~conf ~apply_log ~state)
      | LEADER -> Leader.run (Leader.init ~conf ~apply_log ~state)
    in
    loop next_state_exec
  in
  loop state_exec


let post_command ~(conf : Conf.t) ~logger ~state s =
  let request_json =
    let r : Params.client_command_request = { data = s } in
    Params.client_command_request_to_yojson r
  in
  let request =
    Request_sender.post ~node_id:conf.node_id ~logger ~url_path:"client_command"
      ~request_json
      (* Afford to allow a connection timeout to unavailable server *)
      ~timeout_millis:(conf.request_timeout_millis * 2)
      ~converter:(fun response_json ->
        match Params.client_command_response_of_yojson response_json with
        | Ok param -> Ok (Params.CLIENT_COMMAND_RESPONSE param)
        | Error _ as err -> err)
  in
  match VolatileState.leader_id state.volatile_state with
  | Some node_id ->
      let current_leader_node = Conf.peer_node conf ~node_id in
      request current_leader_node >>= fun result ->
      Lwt.return
        ( match result with
        | Some (Params.CLIENT_COMMAND_RESPONSE x) -> x.success
        | Some _ ->
            Logger.error logger "Shouldn't reach here";
            false
        | None -> false
        )
  | None -> Lwt.return false


let start ~conf_file ~apply_log =
  let conf = Conf.from_file conf_file in
  let state = state conf in
  let logger =
    Logger.create ~node_id:conf.node_id ~mode:None ~output_path:conf.log_file
      ~level:conf.log_level
  in
  let post_command = post_command ~conf ~logger ~state in
  let initial_state_exec =
    Follower.run (Follower.init ~conf ~apply_log ~state)
  in
  {
    conf;
    process =
      process ~conf ~logger ~apply_log ~state ~state_exec:initial_state_exec;
    post_command;
    current_state =
      (fun () ->
        let mode = VolatileState.mode state.volatile_state in
        let term = PersistentState.current_term state.persistent_state in
        let leader =
          match VolatileState.leader_id state.volatile_state with
          | Some x ->
              let leader = Conf.peer_node conf ~node_id:x in
              Some { host = leader.host; port = leader.app_port }
          | None -> None
        in
        { mode; term; leader });
  }
