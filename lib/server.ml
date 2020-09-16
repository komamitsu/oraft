open Core
open Cohttp_lwt_unix
open Lwt
open Base
open Params

(** Followers (§5.2):
  * - Respond to RPCs from candidates and leaders
  *
  * - If election timeout elapses without receiving AppendEntries
  *   RPC from current leader or granting vote to candidate:
  *   convert to candidate
  *)

type t = {
  conf : Conf.t;
  mutable mode : mode option;
  logger : Logger.t;
  lock: Lwt_mutex.t;
  apply_log : apply_log;
  state : State.common;
}

let init ~(conf:Conf.t) ~apply_log ~state =
  let mode = Some FOLLOWER in
  let logger =
      Logger.create ~node_id:conf.node_id ~mode ~output_path:conf.log_file
        ~level:conf.log_level in
  { conf; mode; logger; lock = Lwt_mutex.create (); apply_log; state }

let invalid_request ~logger ~err =
  Logger.warn logger (Printf.sprintf "Invalid request: %s" err);
  Server.respond_string ~status:`Bad_request ~body:"" ()

let server t ~port ~election_timer =
  let logger = t.logger in
  let callback _conn req body =
    Lwt_mutex.with_lock t.lock (fun () ->
        let meth = req |> Request.meth in
        let path = req |> Request.uri |> Uri.path in
        let headers = req |> Request.headers in
        let node_id = Cohttp.Header.get headers "X-Raft-Node-Id" in
        Logger.debug logger
          (Printf.sprintf "Received: %s %s from %s"
             (Cohttp.Code.string_of_method meth)
             path
             ( match node_id with
             | Some x -> x
             | None -> failwith "Missing node_id in HTTP header"
             ));
        body |> Cohttp_lwt.Body.to_string >>= fun body ->
        let json = Yojson.Safe.from_string body in
        match (meth, path) with
        | (`POST, "/append_entries") -> (
            match append_entries_request_of_yojson json with
            | Ok param -> (
              Append_entries_handler.handle ~conf:t.conf ~state:t.state
                ~logger
                ~apply_log:
                  t.apply_log
                  (* If election timeout elapses without receiving AppendEntries
                   * RPC from current leader or granting vote to candidate:
                   * convert to candidate *)
                ~cb_valid_request:(fun () -> Timer.update election_timer)
                ~cb_new_leader:(fun () -> ())
                ~param
            )
            | Error err -> invalid_request ~logger ~err
        )
        | (`POST, "/request_vote") -> (
            match request_vote_request_of_yojson json with
            | Ok param -> (
              Request_vote_handler.handle ~state:t.state
                ~logger
                  (* If election timeout elapses without receiving AppendEntries
                   * RPC from current leader or granting vote to candidate:
                   * convert to candidate *)
                ~cb_valid_request:(fun () -> Timer.update election_timer)
                ~cb_new_leader:(fun () -> ())
                ~param
            )
            | Error err -> invalid_request ~logger ~err
        )
        | _ -> (
            Logger.debug logger
              (Printf.sprintf "Unknown request: %s %s"
                 (Cohttp.Code.string_of_method meth)
                 path);
            Server.respond_string ~status:`Not_found ~body:"" ()
        )
    )
  in
  Server.create ~mode:(`TCP (`Port port)) (Server.make ~callback ())


let run t () =
  Logger.info t.logger "### Follower: Start ###";
  State.log t.state ~logger:t.logger;
  let election_timer =
    Timer.create ~logger:t.logger ~timeout_millis:t.conf.election_timeout_millis
  in
  let server = server t ~port:(Conf.my_node t.conf).port ~election_timer in
  let election_timer_thread =
    Timer.start election_timer ~on_stop:(fun () -> t.mode <- Some CANDIDATE) in
  Logger.debug t.logger "Starting";
  Lwt.join [ election_timer_thread; server ] >>= fun () -> Lwt.return CANDIDATE
