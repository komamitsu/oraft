(* Internal API *)
type append_entries_request = {
  term : int;
  leader_id : int;
  prev_log_term : int;
  prev_log_index : int;
  entries : string list;
  leader_commit : int;
}
[@@deriving show, yojson]

type request_vote_request = {
  term : int;
  candidate_id : int;
  last_log_term : int;
  last_log_index : int;
}
[@@deriving show, yojson]

type request_vote_response = { term : int; vote_granted : bool }
[@@deriving show, yojson]

type append_entries_response = { term : int; success : bool }
[@@deriving show, yojson]

type client_command_request = { data : string } [@@deriving show, yojson]

type client_command_response = { success : bool } [@@deriving show, yojson]

type request =
  | APPEND_ENTRIES_REQUEST of append_entries_request
  | REQUEST_VOTE_REQUEST of request_vote_request
  | CLIENT_COMMAND_REQUEST of client_command_request

type response =
  | APPEND_ENTRIES_RESPONSE of append_entries_response
  | REQUEST_VOTE_RESPONSE of request_vote_response
  | CLIENT_COMMAND_RESPONSE of client_command_response
