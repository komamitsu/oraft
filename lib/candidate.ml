open Core
open Lwt
open Base
open State

let mode = Some CANDIDATE

type t = {
  lock : Lock.t;
  conf : Conf.t;
  logger : Logger.t;
  apply_log : int -> string -> unit;
  state : State.common;
  mutable next_mode : mode option;
}

let init ~conf ~lock ~apply_log ~state =
  {
    lock;
    conf;
    logger = Logger.create conf.node_id mode conf.log_file conf.log_level;
    apply_log;
    state;
    next_mode = None;
  }


let request_vote t =
  Lock.with_lock t.lock (fun () ->
      let request_json =
        let last_log = PersistentLog.last_log t.state.persistent_log in
        let r : Params.request_vote_request =
          {
            term = PersistentState.current_term t.state.persistent_state;
            candidate_id = t.conf.node_id;
            last_log_term = last_log.term;
            last_log_index = last_log.index;
          }
        in
        Params.request_vote_request_to_yojson r
      in
      let request =
        Request_sender.post ~node_id:t.conf.node_id ~logger:t.logger
          ~url_path:"request_vote" ~request_json
          ~converter:(fun response_json ->
            match Params.request_vote_response_of_yojson response_json with
            | Ok param ->
                if PersistentState.detect_new_leader t.logger
                     t.state.persistent_state param.term
                then t.next_mode <- Some FOLLOWER;
                Ok (Params.REQUEST_VOTE_RESPONSE param)
            | Error _ as err -> err)
      in
      Lwt_list.map_p request @@ Conf.peer_nodes t.conf)


let run t () =
  Logger.info t.logger "### Candidate: Start ###";
  Lock.with_lock t.lock (fun () ->
      PersistentState.increment_current_term t.state.persistent_state;
      PersistentState.set_voted_for t.logger t.state.persistent_state
      @@ Some t.conf.node_id);
  State.log t.logger t.state;
  let election_timer = Timer.create t.logger t.conf.election_timeout_millis in
  let handlers = Stdlib.Hashtbl.create 1 in
  let open Params in
  Stdlib.Hashtbl.add handlers
    (`POST, "/append_entries")
    ( (fun json ->
        match append_entries_request_of_yojson json with
        | Ok x -> Ok (APPEND_ENTRIES_REQUEST x)
        | Error _ as e -> e),
      function
      | APPEND_ENTRIES_REQUEST x ->
          Append_entries_handler.handle ~state:t.state ~logger:t.logger
            ~apply_log:t.apply_log
            ~cb_valid_request:(fun () -> Timer.update election_timer)
            ~cb_new_leader:(fun () -> t.next_mode <- Some FOLLOWER)
            ~param:x
      | _ -> failwith "Unexpected state" );
  Stdlib.Hashtbl.add handlers
    (`POST, "/request_vote")
    ( (fun json ->
        match request_vote_request_of_yojson json with
        | Ok x -> Ok (REQUEST_VOTE_REQUEST x)
        | Error _ as e -> e),
      function
      | REQUEST_VOTE_REQUEST x ->
          Request_vote_handler.handle ~state:t.state ~logger:t.logger
            ~cb_valid_request:(fun () -> ())
            ~cb_new_leader:(fun () -> t.next_mode <- Some FOLLOWER)
            ~param:x
      | _ -> failwith "Unexpected state" );
  let server, stopper =
    Request_dispatcher.create (Conf.my_node t.conf).port t.lock t.logger
      handlers
  in
  let votes = request_vote t in
  let received_votes =
    votes
    >>= (fun responses ->
          List.fold_left ~init:1 (* Implicitly voting for myself *)
            ~f:(fun a r ->
              match r with
              | Some param -> (
                  match param with
                  | Params.REQUEST_VOTE_RESPONSE param ->
                      if param.vote_granted then a + 1 else a
                  | _ -> failwith "Unexpected state"
                )
              | None -> a)
            responses
          |> Lwt.return)
    >>= fun n ->
    let majority = Conf.majority_of_nodes t.conf in
    if n >= majority
    then (
      Logger.info t.logger
      @@ Printf.sprintf
           "Received majority votes (received: %d, majority: %d). Moving to \
            Leader"
           n majority;
      Timer.stop election_timer;
      t.next_mode <- Some LEADER
    )
    else (
      Logger.info t.logger
      @@ Printf.sprintf
           "Didn't receive majority votes (received: %d, majority: %d). Trying \
            again"
           n majority;
      t.next_mode <- Some CANDIDATE
    );
    Lwt.return ()
  in
  let election_timer_thread =
    Timer.start election_timer (fun () ->
        Lwt.wakeup stopper ();
        Lwt.cancel votes)
  in
  Lwt.join [ election_timer_thread; received_votes; server ]
  >>= fun () ->
  Lwt.return
  @@
  match t.next_mode with
  | Some LEADER -> LEADER
  | Some CANDIDATE -> CANDIDATE
  | Some _ ->
      Logger.error t.logger "Unexpected state: FOLLOWER";
      CANDIDATE
  | _ ->
      Logger.error t.logger "Unexpected state";
      CANDIDATE
