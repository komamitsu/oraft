open Core
open Lwt
open Base
open State

(** Leaders:
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
let mode = Some LEADER

type t = {
  conf : Conf.t;
  logger : Logger.t;
  apply_log : int -> string -> unit;
  state : State.leader;
  mutable should_step_down : bool;
}

let init ~conf ~apply_log ~state =
  {
    conf;
    logger = Logger.create conf.node_id mode conf.log_file conf.log_level;
    apply_log;
    state =
      {
        common = state;
        volatile_state_on_leader =
          VolatileStateOnLeader.create
            (List.length (Conf.peer_nodes conf))
            (PersistentLog.last_index state.persistent_log);
      };
    should_step_down = false;
  }

let append_entries t =
  let persistent_state = t.state.common.persistent_state in
  let persistent_log = t.state.common.persistent_log in
  let volatile_state = t.state.common.volatile_state in
  let leader_state = t.state.volatile_state_on_leader in
  let current_term = PersistentState.current_term persistent_state in
  let last_log_index = PersistentLog.last_index persistent_log in
  let request i =
    Logger.debug t.logger
      (Printf.sprintf "Peer[%d]: %s" i
         (VolatileStateOnLeader.show_nth_peer leader_state i));
    (** If last log index ≥ nextIndex for a follower: send
     *  AppendEntries RPC with log entries starting at nextIndex
     * - If successful: update nextIndex and matchIndex for
     *   follower (§5.3)
     * - If AppendEntries fails because of log inconsistency:
     *   decrement nextIndex and retry (§5.3)
     *)
    let prev_log_index = VolatileStateOnLeader.next_index leader_state i - 1 in
    let prev_log_term =
      match PersistentLog.get persistent_log prev_log_index with
      | Some log -> log.term
      | None -> -1
    in
    let entries =
      List.init (last_log_index - prev_log_index) ~f:(fun i ->
          let idx = i + prev_log_index + 1 in
          match PersistentLog.get persistent_log idx with
          | Some x -> x.data
          | None ->
              let msg =
                Printf.sprintf "Can't find the log: i:%d, prev_log_index:%d" i
                  prev_log_index
              in
              Logger.error t.logger msg;
              failwith msg)
    in
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
    Logger.debug t.logger
      (Printf.sprintf "Sending append_entries: %s"
         (Yojson.Safe.to_string request_json));
    Request_sender.post ~node_id:t.conf.node_id ~logger:t.logger
      ~url_path:"append_entries" ~request_json ~converter:(fun response_json ->
        match Params.append_entries_response_of_yojson response_json with
        | Ok param when param.success ->
            (** If successful: update nextIndex and matchIndex for follower (§5.3) *)
            VolatileStateOnLeader.set_next_index leader_state i
              (prev_log_index + List.length entries + 1);
            (** All Servers:
              * - If RPC request or response contains term T > currentTerm:
              *   set currentTerm = T, convert to follower (§5.1)
              *)
            if PersistentState.detect_new_leader t.logger persistent_state
                 param.term
            then t.should_step_down <- true;
            Ok (Params.APPEND_ENTRIES_RESPONSE param)
        | Ok _ ->
            (** If AppendEntries fails because of log inconsistency:
             *  decrement nextIndex and retry (§5.3) *)
            VolatileStateOnLeader.next_index leader_state i - 1
            |> VolatileStateOnLeader.set_next_index leader_state i;
            Error "Need to try with decremented index"
        | Error _ as err -> err)
  in
  ( Lwt_list.mapi_p request (Conf.peer_nodes t.conf) >>= fun results ->
    Lwt_list.fold_left_s
      (fun a result -> Lwt.return (if Option.is_some result then a + 1 else a))
      1 (* Implicitly voting for myself *) results )
  >>= fun n ->
  let majority = Conf.majority_of_nodes t.conf in
  Logger.debug t.logger
    (Printf.sprintf
       "Received responses of append_entries. received:%d, majority:%d" n
       majority);
  Lwt.return
    ( if (** If there exists an N such that N > commitIndex, a majority
          *  of matchIndex[i] ≥ N, and log[N].term == currentTerm:
          *  set commitIndex = N (§5.3, §5.4). *)
         n >= Conf.majority_of_nodes t.conf
    then (
      VolatileState.update_commit_index volatile_state last_log_index;
      true )
    else false )

let heartbeat_span_sec t =
  float_of_int t.conf.heartbeat_interval_millis /. 1000.0

let handle_client_command t ~(param : Params.client_command_request) =
  let persistent_log = t.state.common.persistent_log in
  (** If command received from client: append entry to local log,
   *  respond after entry applied to state machine (§5.3) *)
  Logger.debug t.logger
    (Printf.sprintf "Received client_command %s"
       (Params.show_client_command_request param));
  let next_index = PersistentLog.last_index persistent_log + 1 in
  PersistentLog.append persistent_log
    (PersistentState.current_term t.state.common.persistent_state)
    next_index [ param.data ];
  append_entries t >>= fun result ->
  let status, response_body =
    if result
    then
      let body =
        Params.client_command_response_to_yojson { success = true }
        |> Yojson.Safe.to_string
      in
      (`OK, body)
    else (`Internal_server_error, "")
  in
  Cohttp_lwt_unix.Server.respond_string ~status ~body:response_body ()

let run t () =
  Logger.info t.logger "### Leader: Start ###";
  State.log_leader t.logger t.state;
  let handlers = Stdlib.Hashtbl.create 1 in
  let open Params in
  Stdlib.Hashtbl.add handlers
    (`POST, "/append_entries")
    ( (fun json ->
        match append_entries_request_of_yojson json with
        | Ok x -> Ok (APPEND_ENTRIES_REQUEST x)
        | Error _ as e -> e),
      function
      | APPEND_ENTRIES_REQUEST x ->
          Append_entries_handler.handle ~state:t.state.common ~logger:t.logger
            ~apply_log:t.apply_log
            ~cb_valid_request:(fun () -> ())
              (** All Servers:
              * - If RPC request or response contains term T > currentTerm:
              *   set currentTerm = T, convert to follower (§5.1) *)
            ~cb_new_leader:(fun () -> t.should_step_down <- true)
            ~param:x
      | _ -> failwith "Unexpected state" );
  Stdlib.Hashtbl.add handlers
    (`POST, "/request_vote")
    ( (fun json ->
        match request_vote_request_of_yojson json with
        | Ok x -> Ok (REQUEST_VOTE_REQUEST x)
        | Error _ as e -> e),
      function
      | REQUEST_VOTE_REQUEST x ->
          Request_vote_handler.handle ~state:t.state.common ~logger:t.logger
            ~cb_valid_request:(fun () -> ())
              (** All Servers:
              * - If RPC request or response contains term T > currentTerm:
              *   set currentTerm = T, convert to follower (§5.1) *)
            ~cb_new_leader:(fun () -> t.should_step_down <- true)
            ~param:x
      | _ -> failwith "Unexpected state" );
  Stdlib.Hashtbl.add handlers
    (`POST, "/client_command")
    ( (fun json ->
        match client_command_request_of_yojson json with
        | Ok x -> Ok (CLIENT_COMMAND_REQUEST x)
        | Error _ as e -> e),
      function
      | CLIENT_COMMAND_REQUEST x -> handle_client_command t ~param:x
      | _ -> failwith "Unexpected state" );
  let server, stopper =
    Request_dispatcher.create (Conf.my_node t.conf).port t.logger handlers
  in
  (** Upon election: send initial empty AppendEntries RPCs
   *  (heartbeat) to each server; repeat during idle periods to
   *  prevent election timeouts (§5.2) *)
  let append_entries_thread =
    let sleep = heartbeat_span_sec t in
    let rec loop () =
      State.log_leader t.logger t.state;
      append_entries t >>= fun _ ->
      Lwt_unix.sleep sleep >>= fun () ->
      if t.should_step_down
      then (
        Lwt.wakeup stopper ();
        Lwt.return () )
      else loop ()
    in
    loop ()
  in
  Lwt.join [ append_entries_thread; server ] >>= fun () -> Lwt.return FOLLOWER
