open Base
open Core
open State
open Printf
open Result

type t = {
  conf : Conf.t;
  state : leader;
  logger : Logger.t;
  step_down : unit -> unit;
  apply_log : apply_log;
  mutable should_step_down : bool;
  inflight_requests : (int * Lwt_mutex.t) Queue.t;
  mutable threads : unit Lwt.t list option;
}

let return_responses t =
  let match_indexes =
    List.mapi
      ~f:(fun index _ ->
        VolatileStateOnLeader.match_index t.state.volatile_state_on_leader index
      )
      (Conf.peer_nodes t.conf)
  in
  let ordered_match_indexes =
    List.sort ~compare:(fun a b -> a - b) match_indexes
  in
  let num_of_majority = Conf.majority_of_nodes t.conf in
  let match_index_with_majority =
    List.nth_exn ordered_match_indexes (num_of_majority - 1)
  in
  let volatile_state = t.state.common.volatile_state in
  let persistent_log = t.state.common.persistent_log in
  VolatileState.update_commit_index volatile_state match_index_with_majority;
  VolatileState.apply_logs volatile_state ~logger:t.logger ~f:(fun i ->
      match PersistentLog.get persistent_log i with
      | Ok (Some log) ->
          t.apply_log ~node_id:t.conf.node_id ~log_index:log.index
            ~log_data:log.data
      | Ok None -> Error (sprintf "Failed to get the log. index:[%d]" i)
      | Error _ as err -> err
  )
  >>= fun () ->
  Ok
    (Queue.filter_inplace
       ~f:(fun (log_index, lock_per_req) ->
         if match_index_with_majority < log_index
         then (* keep *)
           true
         else (
           Lwt_mutex.unlock lock_per_req;
           (* release *)
           false
         )
       )
       t.inflight_requests
    )


let send_request_and_update_peer_info t ~node_index ~node ~request_json ~entries
    ~prev_log_index =
  let persistent_state = t.state.common.persistent_state in
  let leader_state = t.state.volatile_state_on_leader in
  Logger.debug t.logger ~loc:__LOC__
    (Printf.sprintf "Sending append_entries(node_id:%d): %s" node.id
       (Yojson.Safe.to_string request_json)
    );
  let node = Conf.peer_node t.conf ~node_id:node.id in
  Request_sender.post node ~my_node_id:t.conf.node_id ~logger:t.logger
    ~url_path:"append_entries" ~request_json
    ~timeout_millis:t.conf.request_timeout_millis
    ~converter:(fun response_json ->
      match Params.append_entries_response_of_yojson response_json with
      | Ok param ->
          if PersistentState.detect_newer_term persistent_state ~logger:t.logger
               ~other_term:param.term
          then t.step_down ();

          if param.success
          then (
            (* If successful: update nextIndex and matchIndex for follower (§5.3) *)
            VolatileStateOnLeader.set_match_index leader_state ~logger:t.logger
              node_index
              (prev_log_index + List.length entries);
            let match_index =
              VolatileStateOnLeader.match_index leader_state node_index
            in

            (* Check inflight requests and return responses *)
            return_responses t >>= fun () ->
            VolatileStateOnLeader.set_next_index leader_state node_index
              (match_index + 1);
            (* All Servers:
               * - If RPC request or response contains term T > currentTerm:
               *   set currentTerm = T, convert to follower (§5.1)
            *)
            Ok (Params.APPEND_ENTRIES_RESPONSE param)
          )
          else (
            (* If AppendEntries fails because of log inconsistency:
                *  decrement nextIndex and retry (§5.3) *)
            let next_index =
              VolatileStateOnLeader.next_index leader_state node_index
            in
            if next_index > 1
            then
              VolatileStateOnLeader.set_next_index leader_state node_index
                (next_index - 1);
            Error (sprintf "Need to try with decremented index(%d)" node_index)
          )
      | Error _ as err -> err
  )


let prepare_entries t ~node_index ~node =
  let leader_state = t.state.volatile_state_on_leader in
  let persistent_log = t.state.common.persistent_log in
  let prev_log_index =
    VolatileStateOnLeader.next_index leader_state node_index - 1
  in
  match PersistentLog.last_index persistent_log with
  | Ok last_log_index -> (
      match PersistentLog.get persistent_log prev_log_index with
      | Ok opt_log ->
          let prev_log_term =
            match opt_log with Some log -> log.term | None -> initial_term
          in
          let result_entries =
            List.init (last_log_index - prev_log_index) ~f:(fun i ->
                let idx = i + prev_log_index + 1 in
                match PersistentLog.get persistent_log idx with
                | Ok (Some log) -> Ok log
                | Ok None ->
                    let msg =
                      sprintf
                        "Can't find the log(node_id:%d): i:%d, prev_log_index:%d"
                        node.id i prev_log_index
                    in
                    Logger.error t.logger ~loc:__LOC__ msg;
                    Error msg
                | Error _ as err -> err
            )
          in
          let error_messages =
            List.filter_map result_entries ~f:(fun x ->
                match x with Ok _ -> None | Error msg -> Some msg
            )
          in
          if List.is_empty error_messages
          then
            Ok
              ( prev_log_index,
                prev_log_term,
                List.filter_map
                  ~f:(fun x -> match x with Ok x -> Some x | Error _ -> None)
                  result_entries
              )
          else Error (List.hd_exn error_messages)
      | Error _ as err -> err
    )
  | Error _ as err -> err


let request_append_entry t ~node_index ~node =
  let persistent_state = t.state.common.persistent_state in
  let volatile_state = t.state.common.volatile_state in
  let leader_state = t.state.volatile_state_on_leader in
  let current_term = PersistentState.current_term persistent_state in
  Logger.debug t.logger ~loc:__LOC__
    (Printf.sprintf "Peer[node_id:%d]: %s" node.id
       (VolatileStateOnLeader.show_nth_peer leader_state node_index)
    );
  (* If last log index ≥ nextIndex for a follower: send
   * AppendEntries RPC with log entries starting at nextIndex
   * - If successful: update nextIndex and matchIndex for
   *   follower (§5.3)
   * - If AppendEntries fails because of log inconsistency:
   *   decrement nextIndex and retry (§5.3)
   *)
  match prepare_entries t ~node_index ~node with
  | Ok (prev_log_index, prev_log_term, entries) ->
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
      Ok
        (send_request_and_update_peer_info t ~node_index ~node ~entries
           ~request_json ~prev_log_index
        )
  | Error msg -> Error msg


let interval_in_seconds t =
  float_of_int t.conf.heartbeat_interval_millis /. 1000.0


let append_entries_thread t ~node_index ~node =
  let interval_in_seconds = interval_in_seconds t in
  State.log_leader t.state ~logger:t.logger;
  let rec loop () =
    if t.should_step_down
    then Lwt.return ()
    else (
      let%lwt _ =
        State.log_leader t.state ~logger:t.logger;
        if t.should_step_down
        then (
          Logger.info t.logger ~loc:__LOC__
            (sprintf
               "Avoiding sending append_entries since it's stepping down(node_id:%d)"
               node.id
            );
          Lwt.return_unit
        )
        else (
          match request_append_entry t ~node_index ~node with
          | Ok result ->
              let%lwt _ = result in
              Lwt.return_unit
          | Error msg ->
              Logger.error t.logger ~loc:__LOC__
                (sprintf
                   "Unexpected error occurred in %s (node_id:%d). error:[%s]"
                   __FUNCTION__ node.id msg
                );
              Lwt.return_unit
        )
      in

      (* Sleep if the match_index of the node has cautght up with the last log index *)
      let persistent_log = t.state.common.persistent_log in
      match PersistentLog.last_index persistent_log with
      | Ok last_log_index ->
          let leader_state = t.state.volatile_state_on_leader in
          let match_index =
            VolatileStateOnLeader.match_index leader_state node_index
          in
          let%lwt _ =
            if last_log_index = match_index
            then Lwt_unix.sleep interval_in_seconds
            else Lwt.return_unit
          in
          loop ()
      | Error msg ->
          Logger.error t.logger ~loc:__LOC__ msg;
          let%lwt _ = Lwt_unix.sleep interval_in_seconds in
          loop ()
    )
  in
  loop ()


let stop t =
  Logger.info t.logger ~loc:__LOC__ "Stopping Append_entries_sender";
  t.should_step_down <- true


let wait_append_entries_response t ~log_index =
  let lock_per_req = Lwt_mutex.create () in
  let%lwt _ = Lwt_mutex.lock lock_per_req in
  Queue.enqueue t.inflight_requests (log_index, lock_per_req);
  let%lwt _ = Lwt_mutex.lock lock_per_req in
  Lwt.return ()


let wait_termination t =
  match t.threads with
  | Some threads -> Lwt.join threads
  | None ->
      Logger.warn t.logger ~loc:__LOC__ "Any threads aren't initialized";
      Lwt.return ()


let create ~conf ~state ~logger ~step_down ~apply_log =
  let t =
    {
      conf;
      state;
      logger;
      step_down;
      apply_log;
      should_step_down = false;
      inflight_requests = Queue.create ();
      threads = None;
    }
  in
  t.threads <-
    Some
      (List.mapi (Conf.peer_nodes conf) ~f:(fun index node ->
           append_entries_thread t ~node_index:index ~node
       )
      );
  t
