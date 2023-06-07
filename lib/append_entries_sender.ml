open Core
open Lwt
open State

type t = {
  conf : Conf.t;
  state : leader;
  logger : Logger.t;
  node_id : int;
  step_down : unit -> unit;
  should_step_down : bool;
  mutable last_request_ts : Core.Time_ns.t;
  inflight_requests : (int * Lwt_mutex.t) Queue.t;
  mutable thread : unit Lwt.t option;
}

type lock = Lwt_mutex.t

let lock = Lwt_mutex.create ()

let send_request_and_update_peer_info t ~node_id ~request_json ~entries
    ~prev_log_index =
  let persistent_state = t.state.common.persistent_state in
  let leader_state = t.state.volatile_state_on_leader in
  Logger.debug t.logger
    (Printf.sprintf "Sending append_entries(node_id:%d): %s" t.node_id
       (Yojson.Safe.to_string request_json)
    );
  let node = Conf.peer_node t.conf ~node_id in
  Request_sender.post node ~logger:t.logger ~url_path:"append_entries"
    ~request_json ~timeout_millis:t.conf.request_timeout_millis
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
              node_id
              (prev_log_index + List.length entries);
            let match_index =
              VolatileStateOnLeader.match_index leader_state node_id
            in
            VolatileStateOnLeader.set_next_index leader_state node_id
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
              VolatileStateOnLeader.next_index leader_state node_id
            in
            if next_index > 1
            then
              VolatileStateOnLeader.set_next_index leader_state node_id
                (next_index - 1);
            Error (sprintf "Need to try with decremented index(%d)" t.node_id)
          )
      | Error _ as err -> err
  )


let prepare_entries t ~node_id =
  let leader_state = t.state.volatile_state_on_leader in
  let persistent_log = t.state.common.persistent_log in
  let prev_log_index =
    VolatileStateOnLeader.next_index leader_state node_id - 1
  in
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
        | None ->
            let msg =
              Printf.sprintf "Can't find the log(%d): i:%d, prev_log_index:%d"
                t.node_id i prev_log_index
            in
            Logger.error t.logger msg;
            None
    )
  in
  (prev_log_index, prev_log_term, List.filter_map ~f:(fun x -> x) entries)


let request_append_entry t ~node_id =
  let persistent_state = t.state.common.persistent_state in
  let volatile_state = t.state.common.volatile_state in
  let leader_state = t.state.volatile_state_on_leader in
  let current_term = PersistentState.current_term persistent_state in
  Logger.debug t.logger
    (Printf.sprintf "Peer[%d]: %s" node_id
       (VolatileStateOnLeader.show_nth_peer leader_state node_id)
    );
  (* If last log index ≥ nextIndex for a follower: send
   * AppendEntries RPC with log entries starting at nextIndex
   * - If successful: update nextIndex and matchIndex for
   *   follower (§5.3)
   * - If AppendEntries fails because of log inconsistency:
   *   decrement nextIndex and retry (§5.3)
   *)
  let prev_log_index, prev_log_term, entries = prepare_entries t ~node_id in
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
  send_request_and_update_peer_info t ~node_id ~entries ~request_json
    ~prev_log_index


let heartbeat_interval t =
  Time_ns.Span.create ~ms:t.conf.heartbeat_interval_millis ()


let send_append_entries_if_needed t ~node_id =
  let interval = heartbeat_interval t in
  let now = Time_ns.now () in
  let next_heartbeat = Time_ns.add t.last_request_ts interval in
  if Time_ns.is_earlier next_heartbeat ~than:now
  then (
    t.last_request_ts <- now;
    request_append_entry t ~node_id
  )
  else Lwt.return_none


let conf_interval t =
  Time_ns.Span.create ~ms:t.conf.heartbeat_interval_millis ()


let divided_conf_interval_seconds t n =
  float_of_int t.conf.heartbeat_interval_millis /. float_of_int n /. 1000.0


let append_entries_thread t ~node_id =
  State.log_leader t.state ~logger:t.logger;
  let n = 20 in
  let sleep_interval_seconds = divided_conf_interval_seconds t n in
  let i = ref 0 in
  let rec loop () =
    if t.should_step_down
    then Lwt.return ()
    else (
      let proc =
        if !i = 0 || !i >= n
        then (
          State.log_leader t.state ~logger:t.logger;
          i := 1;
          Lwt_mutex.with_lock lock (fun () ->
              (* TODO: Consider to wrap all the accesses to should_step_down with the lock *)
              if t.should_step_down
              then (
                Logger.info t.logger
                  (sprintf
                     "Avoiding sending append_entries since it's stepping down(%d)"
                     t.node_id
                  );
                Lwt.return_unit
              )
              else
                send_append_entries_if_needed t ~node_id >>= fun _ ->
                Lwt.return_unit
          )
        )
        else (
          i := !i + 1;
          Lwt.return_unit
        )
      in
      proc >>= fun () ->
      Lwt_unix.sleep sleep_interval_seconds >>= fun () -> loop ()
    )
  in
  loop ()


(* FIXME *)
let stop _ = ()

(* FIXME *)
let wait_append_entries_response _ ~log_index =
  if log_index > 0 then lock else lock


let create ~conf ~state ~logger ~node_id ~step_down =
  let t =
    {
      conf;
      state;
      logger;
      node_id;
      step_down;
      should_step_down = false;
      last_request_ts = Time_ns.min_value_representable;
      inflight_requests = Queue.create ();
      thread = None;
    }
  in
  let thread = append_entries_thread t ~node_id in
  t.thread <- Some thread;
  t
