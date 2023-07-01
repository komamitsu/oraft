open Core
open Cohttp_lwt_unix
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
             node.id err body
          );
        None
  )
  else (
    Logger.error logger
    @@ Printf.sprintf "Received an error status code from node %d : %d" node.id
         status_code;
    None
  )


let post ~logger ~url_path ~request_json ~timeout_millis
    ~(converter : Yojson.Safe.t -> (Params.response, string) Result.t)
    ~my_node_id node =
  let request_param =
    request_json |> Yojson.Safe.to_string |> Cohttp_lwt.Body.of_string
  in
  let headers =
    Cohttp.Header.init_with "X-Raft-Node-Id" (string_of_int my_node_id)
  in
  let timeout : Params.response option Lwt.t =
    let%lwt _ = Lwt_unix.sleep (float_of_int timeout_millis /. 1000.0) in
    Logger.warn logger
      (Printf.sprintf "Request timeout. node_id: %d, url_path: %s" node.id
         url_path
      );
    Lwt.return None
  in
  let send_req node =
    let%lwt resp, response_body =
      Client.post ~body:request_param ~headers
        (Uri.of_string
           (Printf.sprintf "http://%s:%d/%s" node.host node.port url_path)
        )
    in
    Lwt.map
      (fun body ->
        try handle_response ~logger ~converter ~node ~resp ~body
        with e ->
          let msg = Stdlib.Printexc.to_string e in
          Logger.error logger
            (Printf.sprintf
               "Failed to handle response body. node_id: %d, error: %s" node.id
               msg
            );
          None
      )
      (Cohttp_lwt.Body.to_string response_body)
  in
  Lwt.catch
    (fun () -> Lwt.pick [ send_req node; timeout ])
    (fun e ->
      let msg = Stdlib.Printexc.to_string e in
      Logger.error logger
        (Printf.sprintf "Failed to send a request. node_id: %d, error: %s"
           node.id msg
        );
      Lwt.return None
    )
