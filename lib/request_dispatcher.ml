open Core
open Cohttp_lwt_unix
open Lwt

type key = Cohttp.Code.meth * string

type converter = Yojson.Safe.t -> (Params.request, string) Result.t

type response = (Cohttp.Response.t * Cohttp_lwt__.Body.t) Lwt.t

type processor = Params.request -> response

type handler = (key, converter * processor) Stdlib.Hashtbl.t

type server = unit Lwt.t

type callback = Cohttp_lwt_unix.Server.conn -> Request.t -> Cohttp_lwt.Body.t -> response

type callback_wrapper = { mutable callback : callback }

type t = {
  logger : Logger.t;
  lock : Lwt_mutex.t;
  server : server;
  callback_wrapper : callback_wrapper
}

let default_callback : callback =
  fun _ _ _ -> Server.respond_string ~status:`Internal_server_error ~body:"" ()

let create ~port ~logger ~lock =
  let callback_wrapper = { callback = default_callback } in
  let callback_func conn req body = callback_wrapper.callback conn req body in
  let server = Server.create ~mode:(`TCP (`Port port)) (Server.make ~callback:callback_func ())
  in
  {
    logger;
    lock;
    server;
    callback_wrapper = callback_wrapper
  }

let set_handler t ~handler =
  let callback _conn req body =
    Lwt_mutex.with_lock t.lock (fun () ->
        let meth = req |> Request.meth in
        let path = req |> Request.uri |> Uri.path in
        let headers = req |> Request.headers in
        let node_id = Cohttp.Header.get headers "X-Raft-Node-Id" in
        Logger.debug t.logger
          (Printf.sprintf "Received: %s %s from %s"
             (Cohttp.Code.string_of_method meth)
             path
             ( match node_id with
             | Some x -> x
             | None -> failwith "Missing node_id in HTTP header"
             ));
        match Stdlib.Hashtbl.find_opt handler (meth, path) with
        | Some (converter, processor) -> (
            body |> Cohttp_lwt.Body.to_string >>= fun body ->
            let json = Yojson.Safe.from_string body in
            match converter json with
            | Ok param -> processor param
            | Error err ->
                Logger.warn t.logger (Printf.sprintf "Invalid request: %s" err);
                Server.respond_string ~status:`Bad_request ~body:"" ()
          )
        | None ->
            Logger.debug t.logger
              (Printf.sprintf "Unknown request: %s %s"
                 (Cohttp.Code.string_of_method meth)
                 path);
            Server.respond_string ~status:`Not_found ~body:"" ())
  in
  t.callback_wrapper.callback <- callback

let disable_handler t =
  t.callback_wrapper.callback <- default_callback

