open Base
open State
open Printf

type leader_node = { host : string; port : int }
type current_state = { mode : mode; term : int; leader : leader_node option }

type t = {
  conf : Conf.t;
  process : unit Lwt.t;
  post_command : string -> bool Lwt.t;
  current_state : unit -> current_state;
}

let state ~(conf : Conf.t) ~logger =
  match PersistentLog.load ~state_dir:conf.state_dir ~logger with
  | Ok persistent_log ->
      Ok
        {
          persistent_state = PersistentState.load ~state_dir:conf.state_dir;
          persistent_log;
          volatile_state = VolatileState.create ();
        }
  | Error msg -> Error msg


let process ~conf ~logger ~apply_log ~state ~state_exec : unit Lwt.t =
  let rec loop state_exec =
    let%lwt next = state_exec () in
    let next_state_exec =
      VolatileState.update_mode state.volatile_state ~logger next;
      match next with
      | FOLLOWER -> Follower.run ~conf ~apply_log ~state
      | CANDIDATE -> Candidate.run ~conf ~apply_log ~state
      | LEADER -> Leader.run ~conf ~apply_log ~state
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
    Request_sender.post ~logger ~url_path:"client_command"
      ~my_node_id:conf.node_id
      ~request_json
        (* Afford to allow a connection timeout to unavailable server *)
      ~timeout_millis:(conf.request_timeout_millis * 2)
      ~converter:(fun response_json ->
        match Params.client_command_response_of_yojson response_json with
        | Ok param -> Ok (Params.CLIENT_COMMAND_RESPONSE param)
        | Error _ as err -> err
    )
  in
  match VolatileState.leader_id state.volatile_state with
  | Some node_id ->
      let current_leader_node = Conf.peer_node conf ~node_id in
      let%lwt result = request current_leader_node in
      Logger.debug logger
        (Printf.sprintf "Sending command to node(%d) : %s" node_id s);
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
  let logger =
    Logger.create ~node_id:conf.node_id ~output_path:conf.log_file
      ~level:conf.log_level ()
  in
  match state ~conf ~logger with
  | Ok state ->
      Logger.info logger "Starting Oraft";
      let post_command = post_command ~conf ~logger ~state in
      let initial_state_exec = Follower.run ~conf ~apply_log ~state in
      Ok
        {
          conf;
          process =
            process ~conf ~logger ~apply_log ~state
              ~state_exec:initial_state_exec;
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
              { mode; term; leader }
            );
        }
  | Error msg ->
      let msg = sprintf "Failed to prepare state. error:[%s]" msg in
      Logger.error logger msg;
      Error msg
