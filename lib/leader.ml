open Core
open Lwt
open Base
open State

(* Leaders:
 * - Upon election: send initial empty AppendEntries RPCs
 *   (heartbeat) to each server; repeat during idle periods to
 *   prevent election timeouts (§5.2)
 *
 * - If command received from client: append entry to local log,
 *   respond after entry applied to state machine (§5.3)
 *
 * - If last log index ≥ nextIndex for a follower: send
 *   AppendEntries RPC with log entries starting at nextIndex
 *
 * - If successful: update nextIndex and matchIndex for
 *   follower (§5.3)
 *
 * - If AppendEntries fails because of log inconsistency:
 *   decrement nextIndex and retry (§5.3)
 *
 * - If there exists an N such that N > commitIndex, a majority
 *   of matchIndex[i] ≥ N, and log[N].term == currentTerm:
 *   set commitIndex = N (§5.3, §5.4).
 *)
let mode = LEADER
let lock = Lwt_mutex.create ()

type t = {
  conf : Conf.t;
  logger : Logger.t;
  apply_log : apply_log;
  state : State.leader;
  mutable should_step_down : bool;
  threads : Append_entries_sender.t list;
}

let init ~conf ~apply_log ~state =
  {
    conf;
    logger =
      Logger.create ~node_id:conf.node_id ~mode ~output_path:conf.log_file
        ~level:conf.log_level ();
    apply_log;
    state =
      {
        common = state;
        volatile_state_on_leader =
          VolatileStateOnLeader.create
            ~n:(List.length (Conf.peer_nodes conf))
            ~last_log_index:(PersistentLog.last_index state.persistent_log);
      };
    should_step_down = false;
  }


let step_down t =
  Logger.info t.logger "Stepping down";
  t.should_step_down <- true


let append_entries t =
  if t.should_step_down
  then (
    Logger.info t.logger
      "Avoiding sending append_entries since it's stepping down";
    Lwt.return false
  )
  else (
    let persistent_log = t.state.common.persistent_log in
    let volatile_state = t.state.common.volatile_state in
    let last_log_index = PersistentLog.last_index persistent_log in
    ( Lwt_list.mapi_p (request_append_entry t) (Conf.peer_nodes t.conf)
    >>= fun results ->
      Lwt_list.fold_left_s
        (fun a result -> Lwt.return (if Option.is_some result then a + 1 else a))
        1 (* Implicitly voting for myself *) results
    )
    >>= fun n ->
    let majority = Conf.majority_of_nodes t.conf in
    Logger.debug t.logger
      (Printf.sprintf
         "Received responses of append_entries. received:%d, majority:%d" n
         majority
      );
    let result =
      if (* If there exists an N such that N > commitIndex, a majority
            * of matchIndex[i] ≥ N, and log[N].term == currentTerm:
            * set commitIndex = N (§5.3, §5.4). *)
         n >= Conf.majority_of_nodes t.conf
      then (
        VolatileState.update_commit_index volatile_state last_log_index;
        VolatileState.apply_logs volatile_state ~logger:t.logger ~f:(fun i ->
            let log = PersistentLog.get_exn persistent_log i in
            t.apply_log ~node_id:t.conf.node_id ~log_index:log.index
              ~log_data:log.data
        );
        true
      )
      else false
    in
    Lwt.return result
  )


let handle_client_command t ~(param : Params.client_command_request) =
  let persistent_log = t.state.common.persistent_log in
  (* If command received from client: append entry to local log,
   * respond after entry applied to state machine (§5.3) *)
  Logger.debug t.logger
    (Printf.sprintf "Received client_command %s"
       (Params.show_client_command_request param)
    );
  let next_index = PersistentLog.last_index persistent_log + 1 in
  let term = PersistentState.current_term t.state.common.persistent_state in
  PersistentLog.append persistent_log
    ~entries:[ { term; index = next_index; data = param.data } ];
  append_entries t >>= fun result ->
  let status, response_body =
    if result
    then (
      let body =
        Params.client_command_response_to_yojson { success = true }
        |> Yojson.Safe.to_string
      in
      (`OK, body)
    )
    else (`Internal_server_error, "")
  in
  Cohttp_lwt_unix.Server.respond_string ~status ~body:response_body ()


let request_handlers t =
  let unexpected_request () =
    Logger.error t.logger
      (sprintf "Unexpected request. should_step_down=%s\n"
         (string_of_bool t.should_step_down)
      );
    Lwt.return (Cohttp.Response.make ~status:`Internal_server_error (), `Empty)
  in
  let handlers = Stdlib.Hashtbl.create 3 in
  let open Params in
  Stdlib.Hashtbl.add handlers (`POST, "/append_entries")
    ( (fun json ->
        match append_entries_request_of_yojson json with
        | Ok x -> Ok (APPEND_ENTRIES_REQUEST x)
        | Error _ as e -> e
      ),
      function
      | APPEND_ENTRIES_REQUEST x when not t.should_step_down ->
          Append_entries_handler.handle ~conf:t.conf ~state:t.state.common
            ~logger:t.logger ~apply_log:t.apply_log
            ~cb_valid_request:(fun () -> ()
            )
              (* All Servers:
               * - If RPC request or response contains term T > currentTerm:
               *   set currentTerm = T, convert to follower (§5.1) *)
            ~cb_newer_term:(fun () -> step_down t)
            ~handle_same_term_as_newer:false ~param:x
      | _ -> unexpected_request ()
    );
  Stdlib.Hashtbl.add handlers (`POST, "/request_vote")
    ( (fun json ->
        match request_vote_request_of_yojson json with
        | Ok x -> Ok (REQUEST_VOTE_REQUEST x)
        | Error _ as e -> e
      ),
      function
      | REQUEST_VOTE_REQUEST x when not t.should_step_down ->
          Request_vote_handler.handle ~state:t.state.common ~logger:t.logger
            ~cb_valid_request:(fun () -> ()
            )
              (* All Servers:
               * - If RPC request or response contains term T > currentTerm:
               *   set currentTerm = T, convert to follower (§5.1) *)
            ~cb_newer_term:(fun () -> step_down t)
            ~param:x
      | _ -> unexpected_request ()
    );
  Stdlib.Hashtbl.add handlers (`POST, "/client_command")
    ( (fun json ->
        match client_command_request_of_yojson json with
        | Ok x -> Ok (CLIENT_COMMAND_REQUEST x)
        | Error _ as e -> e
      ),
      function
      | CLIENT_COMMAND_REQUEST x when not t.should_step_down ->
          handle_client_command t ~param:x
      | _ -> unexpected_request ()
    );
  handlers


let run t () =
  VolatileState.update_leader_id t.state.common.volatile_state ~logger:t.logger
    t.conf.node_id;
  PersistentState.set_voted_for t.state.common.persistent_state ~logger:t.logger
    ~voted_for:(Some t.conf.node_id);
  Logger.info t.logger
  @@ Printf.sprintf "### Leader: Start (term:%d) ###"
  @@ PersistentState.current_term t.state.common.persistent_state;
  State.log_leader t.state ~logger:t.logger;
  let handlers = request_handlers t in
  let server, server_stopper =
    Request_dispatcher.create ~port:(Conf.my_node t.conf).port ~logger:t.logger
      ~lock ~table:handlers
  in
  (* Upon election: send initial empty AppendEntries RPCs
   * (heartbeat) to each server; repeat during idle periods to
   * prevent election timeouts (§5.2) *)
  let append_entries_thread = append_entries_thread t ~server_stopper in
  Lwt.join [ append_entries_thread; server ] >>= fun () -> Lwt.return FOLLOWER
