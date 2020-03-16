open Core
open Cohttp_lwt_unix
open Yojson.Basic
open State

(* Invoked by leader to replicate log entries (§5.3); also used as
 * heartbeat (§5.2).
 *
 * Receiver implementation:
 * 1. Reply false if term < currentTerm (§5.1)
 * 2. Reply false if log doesn’t contain an entry at prevLogIndex
 *     whose term matches prevLogTerm (§5.3)
 * 3. If an existing entry conflicts with a new one (same index
 *    but different terms), delete the existing entry and all that
 *    follow it (§5.3)
 * 4. Append any new entries not already in the log
 * 5. If leaderCommit > commitIndex, set commitIndex =
 *    min(leaderCommit, index of last new entry)
 *)

let append_entries ~(conf : Conf.t) ~logger ~state
    ~(param : Params.append_entries_request) ~(apply_log : Base.apply_log)
    ~cb_valid_request ~cb_new_leader =
  cb_valid_request ();
  VolatileState.update_leader_id state.volatile_state ~logger param.leader_id;
  let persistent_state = state.persistent_state in
  let persistent_log = state.persistent_log in
  let volatile_state = state.volatile_state in
  if PersistentState.detect_new_leader state.persistent_state ~logger
       ~other_term:param.term
  then (
    PersistentState.update_current_term state.persistent_state ~term:param.term;
    cb_new_leader ()
  );
  (* If leaderCommit > commitIndex,
   * set commitIndex = min(leaderCommit, index of last new entry) *)
  if VolatileState.detect_higher_commit_index volatile_state ~logger
       ~other:param.leader_commit
  then
    VolatileState.update_commit_index volatile_state
      (min param.leader_commit (PersistentLog.last_index persistent_log));
  if List.length param.entries > 0
  then (
    Logger.debug logger
      (Printf.sprintf "This param isn't empty, so appending entries(lentgh: %d)"
         (List.length param.entries));
    (* If an existing entry conflicts with a new one (same index
     *  but different terms), delete the existing entry and all that
     *  follow it (§5.3)
     *
     * Append any new entries not already in the log *)
    PersistentLog.append persistent_log
      ~term:(PersistentState.current_term persistent_state)
      ~start:(param.prev_log_index + 1) ~entries:param.entries
  );
  (* All Servers:
   * - If commitIndex > lastApplied: increment lastApplied, apply
   *   log[lastApplied] to state machine (§5.3)
   *)
  VolatileState.apply_logs volatile_state ~logger ~f:(fun i ->
      let log = PersistentLog.get_exn persistent_log i in
      apply_log ~node_id:conf.node_id ~log_index:log.index ~log_data:log.data)


let handle ~conf ~state ~logger ~apply_log ~cb_valid_request ~cb_new_leader
    ~(param : Params.append_entries_request) =
  let persistent_state = state.persistent_state in
  let persistent_log = state.persistent_log in
  let stored_prev_log = PersistentLog.get persistent_log param.prev_log_index in
  let result =
    if PersistentState.detect_old_leader persistent_state ~logger
         ~other_term:param.term
       (* Reply false if term < currentTerm (§5.1) *)
    then false
    else if (not (param.prev_log_term = -1 && param.prev_log_index = 0))
            &&
            match stored_prev_log with
            | Some l -> l.term <> param.prev_log_term
            | None -> true
    then (
      (* Reply false if log doesn’t contain an entry at prevLogIndex whose term matches prevLogTerm (§5.3) *)
      Logger.warn logger
        (Printf.sprintf
           "Received a request that doesn't meet requirement.\nparam:%s,\nstate:%s"
           (Params.show_append_entries_request param)
           (PersistentLog.show persistent_log));
      cb_valid_request ();
      false
    )
    else (
      append_entries ~conf ~logger ~state ~param ~apply_log ~cb_valid_request
        ~cb_new_leader;
      State.log state ~logger;
      true
    )
  in
  let response_body =
    `Assoc
      [
        ("term", `Int (PersistentState.current_term persistent_state));
        ("success", `Bool result);
      ]
    |> to_string
  in
  Server.respond_string ~status:`OK ~body:response_body ()
