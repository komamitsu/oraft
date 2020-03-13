type append_entries_request = {
  (* leader’s term *)
  term : int;
  (* so follower can redirect clients *)
  leader_id : int;
  (* index of log entry immediately preceding new ones *)
  prev_log_term : int;
  (* term of prevLogIndex entry *)
  prev_log_index : int;
  (* log entries to store (empty for heartbeat;
   * may send more than one for efficiency) *)
  entries : State.PersistentLogEntry.t list;
  (* leaderCommit leader’s commitIndex *)
  leader_commit : int;
}
[@@deriving show, yojson]

type append_entries_response = {
  (* currentTerm, for leader to update itself *)
  term : int;
  (* true if follower contained entry matching
   * prevLogIndex and prevLogTerm *)
  success : bool;
}
[@@deriving show, yojson]

type request_vote_request = {
  (* candidate’s term *)
  term : int;
  (* candidate requesting vote *)
  candidate_id : int;
  (* index of candidate’s last log entry (§5.4) *)
  last_log_term : int;
  (* term of candidate’s last log entry (§5.4) *)
  last_log_index : int;
}
[@@deriving show, yojson]

type request_vote_response = {
  (* currentTerm, for candidate to update itself *)
  term : int;
  (* true means candidate received vote *)
  vote_granted : bool;
}
[@@deriving show, yojson]

type client_command_request = { data : string } [@@deriving show, yojson]

(* These are additional parameters for request/response from/to clients *)

type client_command_response = { success : bool } [@@deriving show, yojson]

type request =
  | APPEND_ENTRIES_REQUEST of append_entries_request
  | REQUEST_VOTE_REQUEST of request_vote_request
  | CLIENT_COMMAND_REQUEST of client_command_request

type response =
  | APPEND_ENTRIES_RESPONSE of append_entries_response
  | REQUEST_VOTE_RESPONSE of request_vote_response
  | CLIENT_COMMAND_RESPONSE of client_command_response
