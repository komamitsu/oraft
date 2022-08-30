open Core
open Lwt
open Base
open State

(** Followers (§5.2):
  * - Respond to RPCs from candidates and leaders
  *
  * - If election timeout elapses without receiving AppendEntries
  *   RPC from current leader or granting vote to candidate:
  *   convert to candidate
  *)

let mode = Some FOLLOWER

let lock = Lwt_mutex.create ()

type t = {
  conf : Conf.t;
  logger : Logger.t;
  apply_log : apply_log;
  state : State.common;
}

let init ~conf ~apply_log ~state =
  {
    conf;
    logger =
      Logger.create ~node_id:conf.node_id ~mode ~output_path:conf.log_file
        ~level:conf.log_level;
    apply_log;
    state;
  }

let unexpected_request t =
  Logger.error t.logger "Unexpected request";
  Lwt.return (Cohttp.Response.make ~status:`Internal_server_error (), `Empty)

let request_handler t ~election_timer =
  let handler = Stdlib.Hashtbl.create 2 in
  let open Params in
  Stdlib.Hashtbl.add handler
    (`POST, "/append_entries")
    ( (fun json ->
        match append_entries_request_of_yojson json with
        | Ok x -> Ok (APPEND_ENTRIES_REQUEST x)
        | Error _ as e -> e),
      function
      | APPEND_ENTRIES_REQUEST x ->
          Append_entries_handler.handle ~conf:t.conf ~state:t.state
            ~logger:t.logger
            ~apply_log:
              t.apply_log
              (* If election timeout elapses without receiving AppendEntries
               * RPC from current leader or granting vote to candidate:
               * convert to candidate *)
            ~cb_valid_request:(fun () -> Timer.update election_timer)
            ~cb_newer_term:(fun () -> Timer.reset election_timer)
            ~handle_same_term_as_newer:false
            ~param:x
      | _ -> unexpected_request t);

  Stdlib.Hashtbl.add handler
    (`POST, "/request_vote")
    ( (fun json ->
        match request_vote_request_of_yojson json with
        | Ok x -> Ok (REQUEST_VOTE_REQUEST x)
        | Error _ as e -> e),
      function
      | REQUEST_VOTE_REQUEST x ->
          Request_vote_handler.handle ~state:t.state
            ~logger:
              t.logger
              (* If election timeout elapses without receiving AppendEntries
               * RPC from current leader or granting vote to candidate:
               * convert to candidate *)
            ~cb_valid_request:(fun () -> Timer.update election_timer)
            ~cb_newer_term:(fun () -> ())
            ~param:x
      | _ -> unexpected_request t);

  handler

let run t () =
  VolatileState.reset_leader_id t.state.volatile_state ~logger:t.logger;
  PersistentState.set_voted_for t.state.persistent_state ~logger:t.logger ~voted_for:None;
  Logger.info t.logger @@ Printf.sprintf "### Follower: Start (term:%d) ###" @@ PersistentState.current_term t.state.persistent_state;
  State.log t.state ~logger:t.logger;
  let election_timer =
    Timer.create ~logger:t.logger ~timeout_millis:t.conf.election_timeout_millis
  in
  let handler = request_handler t ~election_timer in
  let server = Request_dispatcher.create ~port:(Conf.my_node t.conf).port ~logger:t.logger ~lock in
  ignore (Request_dispatcher.set_handler server ~handler);
  let election_timer_thread =
    Timer.start election_timer ~on_stop:(fun () -> ())
  in
  Logger.debug t.logger "Starting";
  Lwt.join [ election_timer_thread; (Request_dispatcher.server server)] >>= fun () -> Lwt.return CANDIDATE
