open Core
open Base
open State
open Printf
open Result

(*
 * Candidates (§5.2):
 * - On conversion to candidate, start election:
 *   - Increment currentTerm
 *   - Vote for self
 *   - Reset election timer
 *   - Send RequestVote RPCs to all other servers
 * - If votes received from majority of servers: become leader
 * - If AppendEntries RPC received from new leader: convert to follower
 * - If election timeout elapses: start new election
 *)
let mode = CANDIDATE

type t = {
  conf : Conf.t;
  logger : Logger.t;
  apply_log : apply_log;
  state : State.common;
  lock : Lwt_mutex.t;
  mutable next_mode : mode option;
}

let init ~conf ~apply_log ~state =
  {
    conf;
    logger =
      Logger.create ~node_id:conf.node_id ~mode ~output_path:conf.log_file
        ~level:conf.log_level ();
    apply_log;
    state;
    lock = Lwt_mutex.create ();
    next_mode = None;
  }


let stepdown t ~election_timer =
  t.next_mode <- Some FOLLOWER;
  Timer.stop election_timer;
  ()


let unexpected_error msg =
  Cohttp_lwt_unix.Server.respond_string ~status:`Internal_server_error ~body:msg
    ()


let unexpected_request t =
  Logger.error t.logger ~loc:__LOC__
    (Printf.sprintf "Unexpected request (next_mode: %s)"
       (match t.next_mode with Some x -> Base.show_mode x | None -> "-----")
    );
  Lwt.return (Cohttp.Response.make ~status:`Internal_server_error (), `Empty)


let request_vote t ~election_timer =
  let persistent_state = t.state.persistent_state in
  let persistent_log = t.state.persistent_log in
  let result_request_json =
    match PersistentLog.last_log persistent_log with
    | Ok opt_last_log ->
        let r : Params.request_vote_request =
          match opt_last_log with
          | Some last_log ->
              {
                term = PersistentState.current_term persistent_state;
                candidate_id = t.conf.node_id;
                last_log_term = last_log.term;
                last_log_index = last_log.index;
              }
          | None ->
              {
                term = PersistentState.current_term persistent_state;
                candidate_id = t.conf.node_id;
                last_log_term = initial_term;
                last_log_index = initail_log_index;
              }
        in
        Ok (Params.request_vote_request_to_yojson r)
    | Error _ as err -> err
  in
  match result_request_json with
  | Ok request_json ->
      let request =
        Request_sender.post ~logger:t.logger ~url_path:"request_vote"
          ~request_json ~timeout_millis:t.conf.request_timeout_millis
          ~my_node_id:t.conf.node_id ~converter:(fun response_json ->
            match Params.request_vote_response_of_yojson response_json with
            | Ok param ->
                (* All Servers:
                 * - If RPC request or response contains term T > currentTerm:
                 *   set currentTerm = T, convert to follower (§5.1)
                 *)
                if PersistentState.detect_newer_term persistent_state
                     ~logger:t.logger ~other_term:param.term
                then stepdown t ~election_timer;

                Ok (Params.REQUEST_VOTE_RESPONSE param)
            | Error _ as err -> err
        )
      in
      Lwt_list.map_p request (Conf.peer_nodes t.conf)
  | Error msg ->
      Logger.error t.logger ~loc:__LOC__
        (sprintf "request_vote failed. error:[%s]" msg);
      (* TODO: Revisit here *)
      Lwt_list.map_p Lwt.return []


let request_handlers t ~election_timer =
  let handlers = Stdlib.Hashtbl.create 2 in
  let open Params in
  Stdlib.Hashtbl.add handlers (`POST, "/append_entries")
    ( (fun json ->
        match append_entries_request_of_yojson json with
        | Ok x -> Ok (APPEND_ENTRIES_REQUEST x)
        | Error _ as e -> e
      ),
      function
      | APPEND_ENTRIES_REQUEST x when is_none t.next_mode ->
          Lwt_mutex.with_lock t.lock (fun () ->
              let result =
                Append_entries_handler.handle ~conf:t.conf ~state:t.state
                  ~logger:t.logger ~apply_log:t.apply_log
                  ~cb_valid_request:(fun () -> Timer.update election_timer
                  )
                    (* All Servers:
                     * - If RPC request or response contains term T > currentTerm:
                     *   set currentTerm = T, convert to follower (§5.1) *)
                    (* If AppendEntries RPC received from new leader: convert to follower *)
                  ~cb_newer_term:(fun () -> stepdown t ~election_timer)
                  ~handle_same_term_as_newer:true ~param:x
              in
              match result with
              | Ok response -> response
              | Error msg -> unexpected_error msg
          )
      | _ -> unexpected_request t
    );
  Stdlib.Hashtbl.add handlers (`POST, "/request_vote")
    ( (fun json ->
        match request_vote_request_of_yojson json with
        | Ok x -> Ok (REQUEST_VOTE_REQUEST x)
        | Error _ as e -> e
      ),
      function
      | REQUEST_VOTE_REQUEST x when is_none t.next_mode ->
          Lwt_mutex.with_lock t.lock (fun () ->
              let result =
                Request_vote_handler.handle ~state:t.state ~logger:t.logger
                  ~cb_valid_request:(fun () -> ()
                  )
                    (* All Servers:
                     * - If RPC request or response contains term T > currentTerm:
                     *   set currentTerm = T, convert to follower (§5.1)
                     *)
                  ~cb_newer_term:(fun () -> stepdown t ~election_timer)
                  ~param:x
              in
              match result with
              | Ok response -> response
              | Error msg -> unexpected_error msg
          )
      | _ -> unexpected_request t
    );
  handlers


let collect_votes t ~election_timer ~vote_request =
  let%lwt responses = vote_request in
  let%lwt n =
    Lwt.return
      (List.fold_left ~init:1 (* Implicitly voting for myself *)
         ~f:(fun a r ->
           match r with
           | Some param -> (
               match param with
               | Params.REQUEST_VOTE_RESPONSE param ->
                   if param.vote_granted then a + 1 else a
               | _ ->
                   Logger.error t.logger ~loc:__LOC__ "Unexpected request";
                   a
             )
           | None -> a
         )
         responses
      )
  in
  let majority = Conf.majority_of_nodes t.conf in
  if n >= majority
  then (
    (* If votes received from majority of servers: become leader *)
    Logger.info t.logger ~loc:__LOC__
      (Printf.sprintf
         "Received majority votes (received: %d, majority: %d). Moving to Leader"
         n majority
      );
    Timer.stop election_timer;
    t.next_mode <- Some LEADER
  )
  else
    Logger.info t.logger ~loc:__LOC__
      (Printf.sprintf
         "Didn't receive majority votes (received: %d, majority: %d). Trying again"
         n majority
      );
  Lwt.return ()


let next_mode t =
  match t.next_mode with
  | Some x -> x
  | _ ->
      (* If election timeout elapses: start new election *)
      CANDIDATE


let run ~conf ~apply_log ~state () =
  let t = init ~conf ~apply_log ~state in
  VolatileState.reset_leader_id t.state.volatile_state ~logger:t.logger;
  let persistent_state = t.state.persistent_state in
  (* Increment currentTerm *)
  PersistentState.increment_current_term persistent_state;
  PersistentState.set_voted_for persistent_state ~logger:t.logger
    ~voted_for:(Some t.conf.node_id);
  Logger.info t.logger ~loc:__LOC__
  @@ Printf.sprintf "### Candidate: Start (term:%d) ###"
  @@ PersistentState.current_term persistent_state;
  (* Vote for self *)
  State.log t.state ~logger:t.logger;
  (* Reset election timer *)
  let election_timer =
    Timer.create ~logger:t.logger ~timeout_millis:t.conf.election_timeout_millis
  in
  let handlers = request_handlers t ~election_timer in
  let server, stopper =
    Request_dispatcher.create ~port:(Conf.my_node t.conf).port ~logger:t.logger
      ~table:handlers
  in
  (* Send RequestVote RPCs to all other servers *)
  let vote_request =
    (* TODO: Is this lock needed? *)
    Lwt_mutex.with_lock t.lock (fun () -> request_vote t ~election_timer)
  in
  let received_votes = collect_votes t ~election_timer ~vote_request in
  let election_timer_thread =
    Timer.start election_timer ~on_stop:(fun () ->
        Lwt.wakeup stopper ();
        Lwt.cancel vote_request
    )
  in
  let%lwt _ = Lwt.join [ election_timer_thread; received_votes; server ] in
  Lwt.return (next_mode t)
