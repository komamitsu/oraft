open Base
open State
open Printf

type leader_node = { host : string; port : int }
type current_state = { mode : mode; term : int; leader : leader_node option }

type t = {
  conf : Conf.t;
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


let process ~conf ~logger ~apply_log ~state : unit Lwt.t =
  let exec next_mode =
    VolatileState.update_mode state.volatile_state ~logger next_mode;
    match next_mode with
    | FOLLOWER -> Follower.run ~conf ~apply_log ~state
    | CANDIDATE -> Candidate.run ~conf ~apply_log ~state
    | LEADER -> Leader.run ~conf ~apply_log ~state
  in
  let rec loop next_mode =
    match exec next_mode with
    | Ok next ->
        let%lwt next_mode = next in
        loop next_mode
    | Error msg ->
        let msg =
          sprintf "Failed to process. Starting from %s again. error:[%s]"
            (Base.show_mode Base.FOLLOWER)
            msg
        in
        Logger.error logger ~loc:__LOC__ msg;
        loop FOLLOWER
  in
  loop FOLLOWER


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
      Logger.debug logger ~loc:__LOC__
        (Printf.sprintf "Sending command to node(%d) : %s" node_id s);
      Lwt.return
        ( match result with
        | Some (Params.CLIENT_COMMAND_RESPONSE x) -> x.success
        | Some _ ->
            Logger.error logger ~loc:__LOC__ "Shouldn't reach here";
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
      Logger.info logger ~loc:__LOC__ "Starting Oraft";
      let post_command = post_command ~conf ~logger ~state in
      ignore (process ~conf ~logger ~apply_log ~state);
      Ok
        {
          conf;
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
      Logger.error ~loc:__LOC__ logger msg;
      Error msg
