open Core
open Cohttp_lwt_unix
open State

let handle
    ~state
    ~logger
    ~cb_valid_request
    ~cb_new_leader
    ~(param : Params.request_vote_request) =
  let result =
    let last_log_index = PersistentLog.last_index state.persistent_log in
    let last_log = PersistentLog.get state.persistent_log last_log_index in
    if PersistentState.detect_old_leader logger state.persistent_state
         param.term
    then false
    else if PersistentState.detect_new_leader logger state.persistent_state
              param.term
    then (
      PersistentState.update_current_term state.persistent_state param.term;
      cb_new_leader ();
      true
    )
    else (
      match PersistentState.voted_for state.persistent_state with
      | Some v -> (
          param.candidate_id = v
          && param.last_log_index >= last_log_index
          &&
          match last_log with
          | Some x -> param.last_log_term = x.term
          | None -> true
        )
      | None -> true
    )
  in
  if result
  then (
    cb_valid_request ();
    PersistentState.set_voted_for logger state.persistent_state
    @@ Some param.candidate_id;
    Logger.debug logger
    @@ Printf.sprintf
         "Received request_vote that meets the requirement. param:%s"
         (Params.show_request_vote_request param);
    State.log logger state
  )
  else (
    Logger.debug logger
    @@ Printf.sprintf
         "Received request_vote, but param didn't meet the requirement. \
          param:%s"
         (Params.show_request_vote_request param);
    State.log logger state
  );
  let response_body =
    let record : Params.request_vote_response =
      {
        term = PersistentState.current_term state.persistent_state;
        vote_granted = result;
      }
    in
    record |> Params.request_vote_response_to_yojson |> Yojson.Safe.to_string
  in
  Server.respond_string ~status:`OK ~body:response_body ()
