val handle :
  conf:Conf.t ->
  state:State.common ->
  logger:Logger.t ->
  apply_log:Base.apply_log ->
  cb_valid_request:(unit -> unit) ->
  cb_new_leader:(unit -> unit) ->
  param:Params.append_entries_request ->
  (Cohttp.Response.t * Cohttp_lwt__.Body.t) Lwt.t
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
