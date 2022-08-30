open Core
open Cohttp_lwt_unix
open Lwt

type key = Cohttp.Code.meth * string

type converter = Yojson.Safe.t -> (Params.request, string) Result.t

type response = (Cohttp.Response.t * Cohttp_lwt__.Body.t) Lwt.t

type processor = Params.request -> response

let create ~port ~logger ~lock
    ~(table : (key, converter * processor) Stdlib.Hashtbl.t) :
    unit Lwt.t * unit Lwt.u =
  let stop, server_stopper = Lwt.wait () in
  let callback _conn req body =
    Lwt_mutex.with_lock lock (fun () ->
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
        match Stdlib.Hashtbl.find_opt table (meth, path) with
        | Some (converter, processor) -> (
            body |> Cohttp_lwt.Body.to_string >>= fun body ->
            let json = Yojson.Safe.from_string body in
            match converter json with
            | Ok param -> processor param
            | Error err ->
                Logger.warn logger (Printf.sprintf "Invalid request: %s" err);
                Server.respond_string ~status:`Bad_request ~body:"" ()
          )
        | None ->
            Logger.debug logger
              (Printf.sprintf "Unknown request: %s %s"
                 (Cohttp.Code.string_of_method meth)
                 path);
            Server.respond_string ~status:`Not_found ~body:"" ())
  in
  ( Server.create ~stop ~mode:(`TCP (`Port port)) (Server.make ~callback ()),
    server_stopper )
