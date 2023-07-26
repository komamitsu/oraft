open Core
open Base
open State
open Printf

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

type t = {
  conf : Conf.t;
  logger : Logger.t;
  apply_log : apply_log;
  state : State.leader;
  lock : Lwt_mutex.t;
  mutable should_step_down : bool;
  mutable server_stopper : unit Lwt.u option;
  mutable append_entries_sender : Append_entries_sender.t option;
}

let init ~conf ~apply_log ~state =
  (* TODO : Return Result type*)
  let result = PersistentLog.last_index state.persistent_log in
  let last_log_index = match result with Ok x -> x | Error _ -> -1 in
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
            ~last_log_index;
      };
    lock = Lwt_mutex.create ();
    should_step_down = false;
    server_stopper = None;
    append_entries_sender = None;
  }


let unexpected_error msg =
  Cohttp_lwt_unix.Server.respond_string ~status:`Internal_server_error ~body:msg
    ()


let error fname msg = Error (Printf.sprintf "[%s.%s] %s" __MODULE__ fname msg)

let step_down t =
  Logger.info t.logger "Stepping down";
  t.should_step_down <- true;
  ( match t.append_entries_sender with
  | Some sender ->
      Logger.info t.logger "Calling Append_entries_sender.stop";
      Append_entries_sender.stop sender
  | None -> Logger.error t.logger "Append_entries_sender isn't initalized"
  );
  match t.server_stopper with
  | Some server_stopper ->
      Logger.info t.logger "Calling Lwt.wakeup server_stopper";
      Lwt.wakeup server_stopper ()
  | None -> Logger.error t.logger "Server stopper isn't initalized"


let append_entries t =
  if t.should_step_down
  then (
    Logger.info t.logger
      "Avoiding sending append_entries since it's stepping down";
    Lwt.return (Ok false)
  )
  else (
    let persistent_log = t.state.common.persistent_log in
    match PersistentLog.last_index persistent_log with
    | Ok last_log_index ->
        let%lwt _ =
          match t.append_entries_sender with
          | Some sender ->
              Append_entries_sender.wait_append_entries_response sender
                ~log_index:last_log_index
          | None ->
              Logger.error t.logger "Append_entries_sender isn't initalized";
              Lwt.return ()
        in
        (* TODO Revisite this comment out. The same things are done in AppendEntriesHandler
           VolatileState.update_commit_index volatile_state last_log_index;
           VolatileState.apply_logs volatile_state ~logger:t.logger ~f:(fun i ->
               (* TODO Improve error handling *)
               ignore (
                 match PersistentLog.get persistent_log i with
                 | Ok (Some log) ->
                     Ok (t.apply_log ~node_id:t.conf.node_id ~log_index:log.index ~log_data:log.data)
                 | Ok None -> error __FUNCTION__ (sprintf "failed to get the log. index:[%d]" i)
                 | Error msg -> error __FUNCTION__ msg
               )
             )
           ;
        *)
        (* TODO Fix the return value *)
        Lwt.return (Ok true)
    | Error msg -> Lwt.return (error __FUNCTION__ msg)
  )


let handle_client_command t ~(param : Params.client_command_request) =
  let persistent_log = t.state.common.persistent_log in
  (* If command received from client: append entry to local log,
   * respond after entry applied to state machine (§5.3) *)
  Logger.debug t.logger
    (Printf.sprintf "Received client_command %s"
       (Params.show_client_command_request param)
    );
  match PersistentLog.last_index persistent_log with
  | Ok last_index -> (
      let next_index = last_index + 1 in
      let term = PersistentState.current_term t.state.common.persistent_state in
      let result =
        PersistentLog.append persistent_log
          ~entries:[ { term; index = next_index; data = param.data } ]
      in
      match result with
      | Ok () ->
          let%lwt result = append_entries t in
          let status, response_body =
            match result with
            | Ok success ->
                if success
                then (
                  let body =
                    Params.client_command_response_to_yojson { success = true }
                    |> Yojson.Safe.to_string
                  in
                  (`OK, body)
                )
                else (`Internal_server_error, "Failed in append_entries")
            | Error msg -> (`Internal_server_error, msg)
          in
          Cohttp_lwt_unix.Server.respond_string ~status ~body:response_body ()
      | Error msg -> unexpected_error msg
    )
  | Error msg -> unexpected_error msg


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
          Lwt_mutex.with_lock t.lock (fun () ->
              let result =
                Append_entries_handler.handle ~conf:t.conf ~state:t.state.common
                  ~logger:t.logger ~apply_log:t.apply_log
                  ~cb_valid_request:(fun () -> ()
                  )
                    (* All Servers:
                     * - If RPC request or response contains term T > currentTerm:
                     *   set currentTerm = T, convert to follower (§5.1) *)
                  ~cb_newer_term:(fun () -> step_down t)
                  ~handle_same_term_as_newer:false ~param:x
              in
              match result with
              | Ok response -> response
              | Error msg -> unexpected_error msg
          )
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
          Lwt_mutex.with_lock t.lock (fun () ->
              let result =
                Request_vote_handler.handle ~state:t.state.common
                  ~logger:t.logger
                  ~cb_valid_request:(fun () -> ()
                  )
                    (* All Servers:
                     * - If RPC request or response contains term T > currentTerm:
                     *   set currentTerm = T, convert to follower (§5.1) *)
                  ~cb_newer_term:(fun () -> step_down t)
                  ~param:x
              in
              match result with
              | Ok response -> response
              | Error msg -> unexpected_error msg
          )
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
          Lwt_mutex.with_lock t.lock (fun () -> handle_client_command t ~param:x)
      | _ -> unexpected_request ()
    );
  handlers


let run ~conf ~apply_log ~state () =
  let t = init ~conf ~apply_log ~state in
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
      ~table:handlers
  in
  t.server_stopper <- Some server_stopper;
  (* Upon election: send initial empty AppendEntries RPCs
   * (heartbeat) to each server; repeat during idle periods to
   * prevent election timeouts (§5.2) *)
  let append_entries_sender =
    (*
      module Leader doesn't use `next_index` or `match_index` of the replicas
      while module Append_entries_sender uses only them. So `lock` doesn't
      need to be shared with Append_entries_sender.
    *)
    Append_entries_sender.create ~conf:t.conf ~state:t.state ~logger:t.logger
      ~step_down:(fun () -> step_down t
    )
  in
  t.append_entries_sender <- Some append_entries_sender;
  let%lwt _ =
    Lwt.join
      [ server; Append_entries_sender.wait_termination append_entries_sender ]
  in
  Lwt.return FOLLOWER
