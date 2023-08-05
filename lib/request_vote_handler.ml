open Core
open Cohttp_lwt_unix
open State

(* Invoked by candidates to gather votes (§5.2).
 *
 * Receiver implementation:
 * 1. Reply false if term < currentTerm (§5.1)
 * 2. If votedFor is null or candidateId, and candidate's log is at
 *    least as up-to-date as receiver's log, grant vote (§5.2, §5.4)
 *)

let request_vote ~state ~logger ~cb_newer_term
    ~(param : Params.request_vote_request) =
  let persistent_state = state.persistent_state in
  let persistent_log = state.persistent_log in
  match PersistentLog.last_log persistent_log with
  | Ok opt_last_log ->
      (* Reply false if term < currentTerm (§5.1) *)
      if PersistentState.detect_old_leader persistent_state ~logger
           ~other_term:param.term
      then Ok false
      else (
        if PersistentState.detect_newer_term persistent_state ~logger
             ~other_term:param.term
        then cb_newer_term ();

        (* If votedFor is null or candidateId, and candidate's log is at
           * least as up-to-date as receiver's log, grant vote (§5.2, §5.4) *)
        let up_to_date_as_receiver_log =
          match opt_last_log with
          (* Raft determines which of two logs is more up-to-date by comparing the index and term of the last entries in the
             logs. If the logs have last entries with different terms, then the log with the later term is more up-to-date. If the logs
             end with the same term, then whichever log is longer is more up-to-date. *)
          | Some last_log ->
              param.last_log_term > last_log.term
              || param.last_log_term = last_log.term
                 && param.last_log_index >= last_log.index
          | None -> true
        in
        let last_log_term, last_log_index =
          match opt_last_log with
          | Some last_log -> (last_log.term, last_log.index)
          | None -> (initial_term, initail_log_index)
        in
        Logger.info logger ~loc:__LOC__
          (Printf.sprintf
             "RequestVote's log info is up-to-date? %B (param: {term: %d, index: %d}, last_log: {term: %d, index: %d})"
             up_to_date_as_receiver_log param.last_log_term param.last_log_index
             last_log_term last_log_index
          );

        match PersistentState.voted_for persistent_state with
        | Some v when param.candidate_id = v -> Ok up_to_date_as_receiver_log
        | Some _ -> Ok false
        | None -> Ok up_to_date_as_receiver_log
      )
  | Error msg ->
      let msg =
        Printf.sprintf "Failed to handle request_vote. error:[%s]" msg
      in
      Error msg


let handle ~state ~logger ~cb_valid_request ~cb_newer_term
    ~(param : Params.request_vote_request) =
  let persistent_state = state.persistent_state in
  match request_vote ~state ~logger ~cb_newer_term ~param with
  | Ok result ->
      if result
      then (
        cb_valid_request ();
        PersistentState.set_voted_for persistent_state ~logger
          ~voted_for:(Some param.candidate_id);
        Logger.debug logger ~loc:__LOC__
          (Printf.sprintf
             "Received request_vote that meets the requirement. param:%s"
             (Params.show_request_vote_request param)
          )
      )
      else
        Logger.debug logger ~loc:__LOC__
          (Printf.sprintf
             "Received request_vote, but param didn't meet the requirement. param:%s"
             (Params.show_request_vote_request param)
          );
      State.log state ~logger;
      let response_body =
        let record : Params.request_vote_response =
          {
            term = PersistentState.current_term persistent_state;
            vote_granted = result;
          }
        in
        record |> Params.request_vote_response_to_yojson
        |> Yojson.Safe.to_string
      in
      Ok (Server.respond_string ~status:`OK ~body:response_body ())
  | Error msg -> Error msg
