open Core
open Cohttp_lwt_unix
open Yojson.Basic
open State
open Printf

(* Invoked by leader to replicate log entries (§5.3); also used as
 * heartbeat (§5.2).
 *
 * Receiver implementation:
 * 1. Reply false if term < currentTerm (§5.1)
 * 2. Reply false if log doesn't contain an entry at prevLogIndex
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
    ~cb_newer_term ~handle_same_term_as_newer =
  (* TODO: Revisit whether it's okay to update leader_id w/o any check *)
  VolatileState.update_leader_id state.volatile_state ~logger param.leader_id;
  let persistent_log = state.persistent_log in
  let volatile_state = state.volatile_state in
  if PersistentState.detect_newer_term state.persistent_state ~logger
       ~other_term:param.term
  then cb_newer_term ()
  else if handle_same_term_as_newer
          && PersistentState.detect_same_term state.persistent_state ~logger
               ~other_term:param.term
  then cb_newer_term ();

  let error = ref None in

  (* If leaderCommit > commitIndex,
   * set commitIndex = min(leaderCommit, index of last new entry) *)
  if VolatileState.detect_higher_commit_index volatile_state ~logger
       ~other:param.leader_commit
  then (
    match PersistentLog.last_index persistent_log with
    | Ok last_index ->
        VolatileState.update_commit_index volatile_state
          (min param.leader_commit last_index)
    | Error msg ->
        let msg = sprintf "Failed to handle append_entries. error:[%s]" msg in
        Logger.error logger msg;
        error := Some (Error msg)
  );

  if Option.is_none !error
  then
    if List.length param.entries > 0
    then (
      let first_entry = List.hd_exn param.entries in
      Logger.debug logger
        (sprintf
           "This param isn't empty, so appending entries(lentgh: %d, first_entry.term: %d, first_entry.index: %d)"
           (List.length param.entries)
           first_entry.term first_entry.index
        );
      (* If an existing entry conflicts with a new one (same index
         *  but different terms), delete the existing entry and all that
         *  follow it (§5.3)
         *
         * Append any new entries not already in the log *)
      match PersistentLog.append persistent_log ~entries:param.entries with
      | Ok () -> ()
      | Error msg ->
          let msg = sprintf "Failed to handle append_entries. error:[%s]" msg in
          Logger.error logger msg;
          error := Some (Error msg)
    );

  (* All Servers:
   * - If commitIndex > lastApplied: increment lastApplied, apply
   *   log[lastApplied] to state machine (§5.3)
   *)
  match !error with
  | None ->
      VolatileState.apply_logs volatile_state ~logger ~f:(fun i ->
          (* TODO Improve error handling *)
          match PersistentLog.get persistent_log i with
          | Ok (Some log) ->
              apply_log ~node_id:conf.node_id ~log_index:log.index
                ~log_data:log.data
          | Ok None ->
              let msg =
                sprintf
                  "Failed to handle append_entries. error:[The target log is not found. index:[%d]]"
                  i
              in
              Logger.error logger msg
          | Error msg ->
              let msg =
                sprintf "Failed to handle append_entries. error:[%s]" msg
              in
              Logger.error logger msg
      );
      Ok ()
  | Some error -> error


let log_error_req ~state ~logger ~msg ~(param : Params.append_entries_request) =
  let entries_size = List.length param.entries in
  let persistent_log = state.persistent_log in
  let first_entry =
    if entries_size = 0
    then "None"
    else PersistentLogEntry.show (List.nth_exn param.entries 0)
  in
  let last_entry =
    if entries_size = 0
    then "None"
    else PersistentLogEntry.show (List.nth_exn param.entries (entries_size - 1))
  in
  Logger.warn logger
    (sprintf
       "%s. param:{term:%d, leader_id:%d, prev_log_term:%d, prev_log_index:%d, entries_size:%d, leader_commit:%d, first_entry:%s, last_entry:%s}, state:%s"
       msg param.term param.leader_id param.prev_log_term param.prev_log_index
       entries_size param.leader_commit first_entry last_entry
       (PersistentLog.show persistent_log)
    )


let handle ~conf ~state ~logger ~apply_log ~cb_valid_request ~cb_newer_term
    ~handle_same_term_as_newer ~(param : Params.append_entries_request) =
  let persistent_state = state.persistent_state in
  let persistent_log = state.persistent_log in
  match PersistentLog.get persistent_log param.prev_log_index with
  | Ok stored_prev_log -> (
      let result =
        if PersistentState.detect_old_leader persistent_state ~logger
             ~other_term:param.term
        then (
          (* Reply false if term < currentTerm (§5.1) *)
          log_error_req ~state ~logger
            ~msg:"Received append_entries req that has old team" ~param;
          Ok false
        )
        else if (not (param.prev_log_term = -1 && param.prev_log_index = 0))
                &&
                match stored_prev_log with
                | Some l -> l.term <> param.prev_log_term
                | None -> true
        then (
          cb_valid_request ();
          (* Reply false if log doesn't contain an entry at prevLogIndex whose term matches prevLogTerm (§5.3) *)
          log_error_req ~state ~logger
            ~msg:"Received append_entries req that has unexpected prev_log"
            ~param;
          Ok false
        )
        else (
          cb_valid_request ();
          (* TODO: Error handling *)
          let result =
            append_entries ~conf ~logger ~state ~param ~apply_log ~cb_newer_term
              ~handle_same_term_as_newer
          in
          State.log state ~logger;
          match result with Ok () -> Ok true | Error msg -> Error msg
        )
      in
      match result with
      | Ok success ->
          let response_body =
            `Assoc
              [
                ("term", `Int (PersistentState.current_term persistent_state));
                ("success", `Bool success);
              ]
            |> to_string
          in
          Ok (Server.respond_string ~status:`OK ~body:response_body ())
      | Error msg -> Error msg
    )
  | Error msg ->
      let msg = sprintf "Failed to handle append_entries. error:[%s]" msg in
      Logger.error logger msg;
      Error msg
