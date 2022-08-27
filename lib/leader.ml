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

type t = {
  conf : Conf.t;
  logger : Logger.t;
  lock : Lwt_mutex.t;
  dispatcher : Request_dispatcher.t;
  apply_log : apply_log;
  state : State.leader;
  mutable should_step_down : bool;
  mutable last_request_ts : Time_ns.t option;
}

let init ~(resource:Resource.t) ~apply_log ~state =
  let conf = resource.conf in
  let logger = resource.logger in
  Logger.mode logger ~mode:(Some LEADER);
  {
    conf = resource.conf;
    logger = resource.logger;
    lock = resource.lock;
    dispatcher = resource.dispatcher;
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
    last_request_ts = None;
  }


let step_down t =
  Logger.info t.logger "Stepping down";
  t.should_step_down <- true


let prepare_entries t i =
  let leader_state = t.state.volatile_state_on_leader in
  let persistent_log = t.state.common.persistent_log in
  let prev_log_index = VolatileStateOnLeader.next_index leader_state i - 1 in
  let last_log_index = PersistentLog.last_index persistent_log in
  let prev_log_term =
    match PersistentLog.get persistent_log prev_log_index with
    | Some log -> log.term
    | None -> -1
  in
  let entries =
    List.init (last_log_index - prev_log_index) ~f:(fun i ->
        let idx = i + prev_log_index + 1 in
        match PersistentLog.get persistent_log idx with
        | Some x -> Some x
        | None -> (
            let msg =
              Printf.sprintf "Can't find the log: i:%d, prev_log_index:%d" i
                prev_log_index
            in
            Logger.error t.logger msg;
            None
        )
    )
  in
  (prev_log_index, prev_log_term, List.filter_map ~f:(fun x -> x) entries)


let send_request t i ~request_json ~entries ~prev_log_index =
  let persistent_state = t.state.common.persistent_state in
  let leader_state = t.state.volatile_state_on_leader in
  Logger.debug t.logger
    (Printf.sprintf "Sending append_entries: %s"
       (Yojson.Safe.to_string request_json));
  Request_sender.post ~node_id:t.conf.node_id ~logger:t.logger
    ~url_path:"append_entries" ~request_json
    ~timeout_millis:t.conf.request_timeout_millis
    ~converter:(fun response_json ->
      match Params.append_entries_response_of_yojson response_json with
      | Ok param when param.success ->
          (* If successful: update nextIndex and matchIndex for follower (§5.3) *)
          VolatileStateOnLeader.set_match_index leader_state ~logger:t.logger i
            (prev_log_index + List.length entries);
          let match_index = VolatileStateOnLeader.match_index leader_state i in
          VolatileStateOnLeader.set_next_index leader_state i (match_index + 1);
          (* All Servers:
           * - If RPC request or response contains term T > currentTerm:
           *   set currentTerm = T, convert to follower (§5.1)
           *)
          if PersistentState.detect_newer_term persistent_state ~logger:t.logger
               ~other_term:param.term
          then step_down t;
          Ok (Params.APPEND_ENTRIES_RESPONSE param)
      | Ok _ ->
          (* If AppendEntries fails because of log inconsistency:
           *  decrement nextIndex and retry (§5.3) *)
          let next_index = VolatileStateOnLeader.next_index leader_state i in
          VolatileStateOnLeader.set_next_index leader_state i (next_index - 1);
          Error "Need to try with decremented index"
      | Error _ as err -> err)


let request_append_entry t i =
  let persistent_state = t.state.common.persistent_state in
  let volatile_state = t.state.common.volatile_state in
  let leader_state = t.state.volatile_state_on_leader in
  let current_term = PersistentState.current_term persistent_state in
  Logger.debug t.logger
    (Printf.sprintf "Peer[%d]: %s" i
       (VolatileStateOnLeader.show_nth_peer leader_state i));
  (* If last log index ≥ nextIndex for a follower: send
   * AppendEntries RPC with log entries starting at nextIndex
   * - If successful: update nextIndex and matchIndex for
   *   follower (§5.3)
   * - If AppendEntries fails because of log inconsistency:
   *   decrement nextIndex and retry (§5.3)
   *)
  let prev_log_index, prev_log_term, entries = prepare_entries t i in
  let request_json =
    let r : Params.append_entries_request =
      {
        term = current_term;
        leader_id = t.conf.node_id;
        prev_log_term;
        prev_log_index;
        entries;
        leader_commit = VolatileState.commit_index volatile_state;
      }
    in
    Params.append_entries_request_to_yojson r
  in
  send_request t i ~entries ~request_json ~prev_log_index


let append_entries t =
  if t.should_step_down then (
    Logger.info t.logger "Avoiding sending append_entries since it's stepping down";
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
        1 (* Implicitly voting for myself *) results )
    >>= fun n ->
    let majority = Conf.majority_of_nodes t.conf in
    Logger.debug t.logger
      (Printf.sprintf
        "Received responses of append_entries. received:%d, majority:%d" n
        majority);
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
              ~log_data:log.data);
        true
      )
      else false
    in
    t.last_request_ts <- Some (Time_ns.now ());
    Lwt.return result
  )

let heartbeat_span_sec t =
  let configured =
    Time_ns.Span.create ~ms:t.conf.heartbeat_interval_millis ()
  in
  let now = Time_ns.now () in
  let wait =
    match t.last_request_ts with
    | Some x ->
        let next_fire_ts = Time_ns.add x configured in
        Time_ns.diff next_fire_ts now
    | None -> configured
  in
  Time_ns.Span.to_sec wait


let handle_client_command t ~(param : Params.client_command_request) =
  let persistent_log = t.state.common.persistent_log in
  (* If command received from client: append entry to local log,
   * respond after entry applied to state machine (§5.3) *)
  Logger.debug t.logger
    (Printf.sprintf "Received client_command %s"
       (Params.show_client_command_request param));
  let next_index = PersistentLog.last_index persistent_log + 1 in
  let term = PersistentState.current_term t.state.common.persistent_state in
  PersistentLog.append persistent_log ~term ~start:next_index
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


let request_handler t =
  let unexpected_request = fun () -> (
    Logger.error t.logger "Unexpected request";
    Lwt.return (Cohttp.Response.make ~status:`Internal_server_error (), `Empty)
  )
  in
  let handler = Stdlib.Hashtbl.create 3 in
  let open Params in
  Stdlib.Hashtbl.add handler
    (`POST, "/append_entries")
    ( (fun json ->
        match append_entries_request_of_yojson json with
        | Ok x -> Ok (APPEND_ENTRIES_REQUEST x)
        | Error _ as e -> e),
      function
      | APPEND_ENTRIES_REQUEST x ->
          Append_entries_handler.handle ~conf:t.conf ~state:t.state.common
            ~logger:t.logger ~apply_log:t.apply_log
            ~cb_valid_request:(fun () -> ())
              (* All Servers:
               * - If RPC request or response contains term T > currentTerm:
               *   set currentTerm = T, convert to follower (§5.1) *)
            ~cb_newer_term:(fun () -> step_down t)
            ~handle_same_term_as_newer:false
            ~param:x
      | _ -> unexpected_request ());
  Stdlib.Hashtbl.add handler
    (`POST, "/request_vote")
    ( (fun json ->
        match request_vote_request_of_yojson json with
        | Ok x -> Ok (REQUEST_VOTE_REQUEST x)
        | Error _ as e -> e),
      function
      | REQUEST_VOTE_REQUEST x ->
          Request_vote_handler.handle ~state:t.state.common ~logger:t.logger
            ~cb_valid_request:(fun () -> ())
              (* All Servers:
               * - If RPC request or response contains term T > currentTerm:
               *   set currentTerm = T, convert to follower (§5.1) *)
            ~cb_newer_term:(fun () -> step_down t)
            ~param:x
      | _ -> unexpected_request ());
  Stdlib.Hashtbl.add handler
    (`POST, "/client_command")
    ( (fun json ->
        match client_command_request_of_yojson json with
        | Ok x -> Ok (CLIENT_COMMAND_REQUEST x)
        | Error _ as e -> e),
      function
      | CLIENT_COMMAND_REQUEST x -> handle_client_command t ~param:x
      | _ -> unexpected_request ());
  handler


let append_entries_thread t =
  State.log_leader t.state ~logger:t.logger;
  let n = 20 in
  let sleep = heartbeat_span_sec t /. (float_of_int n) in
  let i = ref 0 in
  let rec loop () =
    if t.should_step_down
    then (
      Logger.debug t.logger "Quiting Leader";
      Lwt.return ()
    )
    else (
      let proc = if !i = 0 || !i >= n then (
        State.log_leader t.state ~logger:t.logger;
        i := 1;
        Lwt_mutex.with_lock t.lock (fun () ->
          (* TODO: The result of append_entries can be ignored? *)
          append_entries t >>= fun _ -> Lwt.return ()
        )
      )
      else (
        i := !i + 1;
        Lwt.return ()
      )
      in
      proc >>= fun () -> Lwt_unix.sleep sleep >>= fun () -> loop ()
    )
  in
  loop ()


let run t () =
  VolatileState.update_leader_id
    t.state.common.volatile_state ~logger:t.logger t.conf.node_id;
  PersistentState.set_voted_for t.state.common.persistent_state ~logger:t.logger ~voted_for:(Some t.conf.node_id);
  Logger.info t.logger @@
    Printf.sprintf "### Leader: Start (term:%d) ###" @@ PersistentState.current_term t.state.common.persistent_state;
  State.log_leader t.state ~logger:t.logger;
  let handler = request_handler t in
  ignore (Request_dispatcher.set_handler t.dispatcher ~handler);
  (* Upon election: send initial empty AppendEntries RPCs
   * (heartbeat) to each server; repeat during idle periods to
   * prevent election timeouts (§5.2) *)
  Lwt.choose [ (append_entries_thread t); (Request_dispatcher.server t.dispatcher) ] >>= fun () -> Lwt.return FOLLOWER
