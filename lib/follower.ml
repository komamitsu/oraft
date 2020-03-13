open Core
open Lwt
open Base

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


let request_handlers t ~election_timer =
  let handlers = Stdlib.Hashtbl.create 2 in
  let open Params in
  Stdlib.Hashtbl.add handlers
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
            ~cb_new_leader:(fun () -> ())
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
          Request_vote_handler.handle ~state:t.state
            ~logger:
              t.logger
              (* If election timeout elapses without receiving AppendEntries
               * RPC from current leader or granting vote to candidate:
               * convert to candidate *)
            ~cb_valid_request:(fun () -> Timer.update election_timer)
            ~cb_new_leader:(fun () -> ())
            ~param:x
      | _ -> failwith "Unexpected state" );
  handlers


let run t () =
  Logger.info t.logger "### Follower: Start ###";
  State.log t.state ~logger:t.logger;
  let election_timer =
    Timer.create ~logger:t.logger ~timeout_millis:t.conf.election_timeout_millis
  in
  let handlers = request_handlers t ~election_timer in
  let server, server_stopper =
    Request_dispatcher.create ~port:(Conf.my_node t.conf).port ~logger:t.logger
      ~lock ~table:handlers
  in
  let election_timer_thread =
    Timer.start election_timer ~on_stop:(fun () -> Lwt.wakeup server_stopper ())
  in
  Logger.debug t.logger "Starting";
  Lwt.join [ election_timer_thread; server ] >>= fun () -> Lwt.return CANDIDATE
