open Core
open Cohttp_lwt_unix
open Yojson.Basic
open State

(* Invoked by leader to replicate log entries ($B!x(B5.3); also used as
 * heartbeat ($B!x(B5.2).
 *
 * Receiver implementation:
 * 1. Reply false if term < currentTerm ($B!x(B5.1)
 * 2. Reply false if log doesn$B!G(Bt contain an entry at prevLogIndex
 *     whose term matches prevLogTerm ($B!x(B5.3)
 * 3. If an existing entry conflicts with a new one (same index
 *    but different terms), delete the existing entry and all that
 *    follow it ($B!x(B5.3)
 * 4. Append any new entries not already in the log
 * 5. If leaderCommit > commitIndex, set commitIndex =
 *    min(leaderCommit, index of last new entry)
 *)

let append_entries ~(conf : Conf.t) ~logger ~state
    ~(param : Params.append_entries_request) ~(apply_log : Base.apply_log)
    ~cb_newer_term ~handle_same_term_as_newer =
  (* TODO: Revisit whether it's okay to update leader_id w/o any check *)
  VolatileState.update_leader_id state.volatile_state ~logger param.leader_id;
  let persistent_log = state.persistent_log in
  let volatile_state = state.volatile_state in
  if PersistentState.detect_newer_term state.persistent_state ~logger
       ~other_term:param.term
  then cb_newer_term ()
  else if handle_same_term_as_newer &&
    PersistentState.detect_same_term state.persistent_state ~logger
        ~other_term:param.term
  then cb_newer_term ()
  ;

  (* If leaderCommit > commitIndex,
   * set commitIndex = min(leaderCommit, index of last new entry) *)
  if VolatileState.detect_higher_commit_index volatile_state ~logger
       ~other:param.leader_commit
  then
    VolatileState.update_commit_index volatile_state
      (min param.leader_commit (PersistentLog.last_index persistent_log));
  if List.length param.entries > 0
  then (
    let first_entry = List.hd_exn param.entries in
    Logger.debug logger
      (Printf.sprintf "This param isn't empty, so appending entries(lentgh: %d, first_entry.term: %d, first_entry.index: %d)"
          first_entry.term
          first_entry.index
          (List.length param.entries));
    (* If an existing entry conflicts with a new one (same index
     *  but different terms), delete the existing entry and all that
     *  follow it ($B!x(B5.3)
     *
     * Append any new entries not already in the log *)
    PersistentLog.append persistent_log ~entries:param.entries
  );
  (* All Servers:
   * - If commitIndex > lastApplied: increment lastApplied, apply
   *   log[lastApplied] to state machine ($B!x(B5.3)
   *)
  VolatileState.apply_logs volatile_state ~logger ~f:(fun i ->
      let log = PersistentLog.get_exn persistent_log i in
      apply_log ~node_id:conf.node_id ~log_index:log.index ~log_data:log.data)

let log_error_req ~state ~logger ~msg ~(param : Params.append_entries_request) =
  let entries_size = List.length param.entries in
  let persistent_log = state.persistent_log in
    Logger.warn logger
      (Printf.sprintf
        "%s. param:{term:%d, leader_id:%d, prev_log_term:%d, prev_log_index:%d, entries_size:%d, leader_commit:%d, first_entry:%s, last_entry:%s}, state:%s"
        msg param.term param.leader_id param.prev_log_term param.prev_log_index
        entries_size
        param.leader_commit
        (PersistentLogEntry.show (List.nth_exn param.entries 0))
        (PersistentLogEntry.show (List.nth_exn param.entries (entries_size - 1)))
        (PersistentLog.show persistent_log))

let handle ~conf ~state ~logger ~apply_log ~cb_valid_request
    ~cb_newer_term ~handle_same_term_as_newer
    ~(param : Params.append_entries_request) =
  let persistent_state = state.persistent_state in
  let persistent_log = state.persistent_log in
  let stored_prev_log = PersistentLog.get persistent_log param.prev_log_index in
  cb_valid_request ();
  let result =
    if PersistentState.detect_old_leader persistent_state ~logger ~other_term:param.term
    then (
       (* Reply false if term < currentTerm ($B!x(B5.1) *)
      log_error_req ~state ~logger ~msg:"Received append_entries req that has old team" ~param;
      false
    )
    else if (not (param.prev_log_term = -1 && param.prev_log_index = 0))
            &&
            match stored_prev_log with
            | Some l -> l.term <> param.prev_log_term
            | None -> true
    then (
      (* Reply false if log doesn$B!G(Bt contain an entry at prevLogIndex whose term matches prevLogTerm ($B!x(B5.3) *)
      log_error_req ~state ~logger ~msg:"Received append_entries req that has unexpected prev_log" ~param;
      false
    )
    else (
      append_entries ~conf ~logger ~state ~param ~apply_log ~cb_newer_term ~handle_same_term_as_newer;
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
