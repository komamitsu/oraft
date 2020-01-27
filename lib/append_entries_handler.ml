open Core
open Cohttp_lwt_unix
open Yojson.Basic
open State

(** Invoked by leader to replicate log entries (§5.3); also used as
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

let append_entries
    ~logger
    ~state
    ~(param : Params.append_entries_request)
    ~apply_log
    ~cb_valid_request
    ~cb_new_leader =
  cb_valid_request ();

  if PersistentState.detect_new_leader logger state.persistent_state param.term
  then (
    PersistentState.update_current_term state.persistent_state param.term;
    cb_new_leader ()
  );

  (** If leaderCommit > commitIndex,
   *  set commitIndex = min(leaderCommit, index of last new entry) *)
  if VolatileState.detect_higher_commit_index logger state.volatile_state
       param.leader_commit
  then
    (* TODO: Revisit -> "index of last new entry" *)
    VolatileState.update_commit_index state.volatile_state param.leader_commit;

  if List.length param.entries > 0
  then (
    Logger.debug logger
    @@ Printf.sprintf "This param isn't empty, so appending entries(lentgh: %d)"
    @@ List.length param.entries;
    (** If an existing entry conflicts with a new one (same index
     *  but different terms), delete the existing entry and all that
     *  follow it (§5.3)
     *
     * Append any new entries not already in the log *)
    PersistentLog.append state.persistent_log
      (PersistentState.current_term state.persistent_state)
      (param.prev_log_index + 1) param.entries
  );

  (** All Servers:
    * - If commitIndex > lastApplied: increment lastApplied, apply
    *   log[lastApplied] to state machine (§5.3)
    *)
  VolatileState.apply_logs state.volatile_state (fun i ->
      Logger.debug logger
      @@ Printf.sprintf
           "Applying %dth entry. state.volatile_state.commit_index: %d" i
      @@ VolatileState.commit_index state.volatile_state;
      let log = PersistentLog.get_exn state.persistent_log i in
      apply_log log.index log.data;
      Logger.debug logger
      @@ Printf.sprintf "Applyed %dth entry: %s" i
      @@ PersistentLogEntry.show log)


let handle
    ~state
    ~logger
    ~apply_log
    ~cb_valid_request
    ~cb_new_leader
    ~(param : Params.append_entries_request) =
  let result =
    if PersistentState.detect_old_leader logger state.persistent_state
         param.term
    (** Reply false if term < currentTerm (§5.1) *)
    then false
    else if PersistentLog.last_index state.persistent_log < param.prev_log_index
            || PersistentLog.last_index state.persistent_log <> 0
               && Option.is_none
                  @@ PersistentLog.get state.persistent_log param.prev_log_index
    then (
      (* TODO: Reply false if log doesn’t contain an entry at prevLogIndex
       *       whose term matches prevLogTerm (§5.3) *)
      Logger.warn logger
      @@ Printf.sprintf
           "Received a request that doesn't meet requirement.\n\
            param:%s,\n\
            state:%s"
           (Params.show_append_entries_request param)
           (PersistentLog.show state.persistent_log);
      cb_valid_request ();
      false
    )
    else (
      append_entries ~logger ~state ~param ~apply_log ~cb_valid_request
        ~cb_new_leader;
      State.log logger state;
      true
    )
  in
  let response_body =
    to_string
    @@ `Assoc
         [
           ("term", `Int (PersistentState.current_term state.persistent_state));
           ("success", `Bool result);
         ]
  in
  Server.respond_string ~status:`OK ~body:response_body ()
