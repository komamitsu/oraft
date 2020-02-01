open Core
open Cohttp_lwt_unix
open State

(* Invoked by candidates to gather votes (§5.2).
 *
 * Receiver implementation:
 * 1. Reply false if term < currentTerm (§5.1)
 * 2. If votedFor is null or candidateId, and candidate’s log is at
 *    least as up-to-date as receiver’s log, grant vote (§5.2, §5.4)
 *)

let request_vote ~state ~logger ~cb_new_leader
    ~(param : Params.request_vote_request) =
  let persistent_state = state.persistent_state in
  let persistent_log = state.persistent_log in
  let last_log_index = PersistentLog.last_index persistent_log in
  let last_log = PersistentLog.get persistent_log last_log_index in
  (* Reply false if term < currentTerm (§5.1) *)
  if PersistentState.detect_old_leader persistent_state ~logger
       ~other_term:param.term
  then false
  else if PersistentState.detect_new_leader persistent_state ~logger
            ~other_term:param.term
  then (
    PersistentState.update_current_term persistent_state ~term:param.term;
    cb_new_leader ();
    true
  )
  else (
    (* If votedFor is null or candidateId, and candidate’s log is at
     * least as up-to-date as receiver’s log, grant vote (§5.2, §5.4) *)
    let up_to_date_as_receiver_log =
      param.last_log_index >= last_log_index
      &&
      match last_log with
      | Some x -> param.last_log_term = x.term
      | None -> true
    in
    match PersistentState.voted_for persistent_state with
    | Some v when param.candidate_id = v -> up_to_date_as_receiver_log
    | Some _ -> false
    | None -> up_to_date_as_receiver_log
  )


let handle ~state ~logger ~cb_valid_request ~cb_new_leader
    ~(param : Params.request_vote_request) =
  let persistent_state = state.persistent_state in
  let result = request_vote ~state ~logger ~cb_new_leader ~param in
  if result
  then (
    cb_valid_request ();
    PersistentState.set_voted_for persistent_state ~logger
      ~voted_for:(Some param.candidate_id);
    Logger.debug logger
      (Printf.sprintf
         "Received request_vote that meets the requirement. param:%s"
         (Params.show_request_vote_request param))
  )
  else
    Logger.debug logger
      (Printf.sprintf
         "Received request_vote, but param didn't meet the requirement. param:%s"
         (Params.show_request_vote_request param));
  State.log state ~logger;
  let response_body =
    let record : Params.request_vote_response =
      {
        term = PersistentState.current_term persistent_state;
        vote_granted = result;
      }
    in
    record |> Params.request_vote_response_to_yojson |> Yojson.Safe.to_string
  in
  Server.respond_string ~status:`OK ~body:response_body ()
