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

type t = {
  lock : Lock.t;
  conf : Conf.t;
  logger : Logger.t;
  apply_log : int -> string -> unit;
  state : State.common;
}

let init ~conf ~lock ~apply_log ~state =
  {
    lock;
    conf;
    logger = Logger.create conf.node_id mode conf.log_file conf.log_level;
    apply_log;
    state;
  }

let run t () =
  Logger.info t.logger "### Follower: Start ###";
  State.log t.logger t.state;
  let election_timer = Timer.create t.logger t.conf.election_timeout_millis in
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
          Append_entries_handler.handle ~state:t.state ~logger:t.logger
            ~apply_log:
              t.apply_log
              (** If election timeout elapses without receiving AppendEntries
               *  RPC from current leader or granting vote to candidate:
               *  convert to candidate *)
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
              (** If election timeout elapses without receiving AppendEntries
               *  RPC from current leader or granting vote to candidate:
               *  convert to candidate *)
            ~cb_valid_request:(fun () -> Timer.update election_timer)
            ~cb_new_leader:(fun () -> ())
            ~param:x
      | _ -> failwith "Unexpected state" );
  let server, stopper =
    Request_dispatcher.create (Conf.my_node t.conf).port t.lock t.logger
      handlers
  in
  let election_timer_thread =
    Timer.start election_timer (fun () -> Lwt.wakeup stopper ())
  in
  Logger.debug t.logger "Starting";
  Lwt.join [ election_timer_thread; server ] >>= fun () -> Lwt.return CANDIDATE
