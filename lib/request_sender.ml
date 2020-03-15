open Core
open Cohttp_lwt_unix
open Lwt
open Base

let handle_response ~logger ~converter ~node ~resp ~body =
  let status_code = resp |> Response.status |> Cohttp.Code.code_of_status in
  if status_code / 100 = 2
  then (
    Logger.debug logger
      (Printf.sprintf "Received response from node: %d, body: %s" node.id body);
    let json = Yojson.Safe.from_string body in
    match converter json with
    | Ok param -> Some param
    | Error err ->
        Logger.error logger
          (Printf.sprintf
             "Received an error response from node %d. err: %s, body: %s"
             node.id err body);
        None
  )
  else (
    Logger.error logger
    @@ Printf.sprintf "Received an error status code from node %d : %d" node.id
         status_code;
    None
  )


let post ~node_id ~logger ~url_path ~request_json ~timeout_millis
    ~(converter : Yojson.Safe.t -> (Params.response, string) Result.t) node =
  let request_param =
    request_json |> Yojson.Safe.to_string |> Cohttp_lwt.Body.of_string
  in
  let headers =
    Cohttp.Header.init_with "X-Raft-Node-Id" (string_of_int node_id)
  in
  let timeout : Params.response option Lwt.t =
    Lwt_unix.sleep (float_of_int timeout_millis /. 1000.0) >>= fun () ->
    Logger.warn logger
      (Printf.sprintf "Request timeout. node_id: %d, url_path: %s" node.id url_path);
    Lwt.return None
  in
  let send_req node =
    Client.post ~body:request_param ~headers
      (Uri.of_string
         (Printf.sprintf "http://%s:%d/%s" node.host node.port url_path))
    >>= fun (resp, body) ->
    body |> Cohttp_lwt.Body.to_string >|= fun body ->
    try handle_response ~logger ~converter ~node ~resp ~body
    with e ->
      let msg = Stdlib.Printexc.to_string e in
      Logger.error logger
        (Printf.sprintf "Failed to handle response body. node_id: %d, error: %s"
           node.id msg);
      None
  in
  Lwt.catch
    (fun () -> Lwt.pick [ send_req node; timeout ])
    (fun e ->
      let msg = Stdlib.Printexc.to_string e in
      Logger.error logger
        (Printf.sprintf "Failed to send a request. node_id: %d, error: %s"
           node.id msg);
      Lwt.return None)
