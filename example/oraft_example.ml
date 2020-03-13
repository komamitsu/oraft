open Lwt
open Cohttp_lwt_unix

let kvs = Hashtbl.create 64

let lock = Lwt_mutex.create ()

let parse_command s =
  let parts = Core.String.split ~on:' ' s in
  let cmd = List.hd parts in
  let args = List.tl parts in
  (cmd, args)


let with_flush_stdout f =
  f ();
  Core.Out_channel.flush stdout


let kvs_set args = Hashtbl.replace kvs (List.nth args 0) (List.nth args 1)

let kvs_incr args =
  let k = List.nth args 0 in
  let v =
    match Hashtbl.find_opt kvs k with
    | Some x -> (
        match int_of_string_opt x with Some i -> i | None -> 0
      )
    | None -> 0
  in
  let incremented = string_of_int (v + 1) in
  Hashtbl.replace kvs k incremented


let kvs_cas args =
  let k = List.nth args 0 in
  let expected = List.nth args 1 in
  let v = List.nth args 2 in
  match Hashtbl.find_opt kvs k with
  | Some x when x = expected -> Hashtbl.replace kvs k v
  | Some x ->
      with_flush_stdout (fun () ->
          Printf.printf "!!!! INVALID CAS : k=%s, expected=%s, v=%s !!!!\n" k
            expected x)
  | None -> ()


let oraft conf_file =
  Oraft.start ~conf_file ~apply_log:(fun ~node_id ~log_index ~log_data ->
      with_flush_stdout (fun () ->
          Printf.printf "<<<< %d: APPLY(%d) : %s >>>>\n" node_id log_index
            log_data);
      let cmd, args = parse_command log_data in
      match cmd with
      | "SET" -> kvs_set args
      | "INCR" -> kvs_incr args
      | "CAS" -> kvs_cas args
      | _ -> ())


let redirect_to_leader leader_host port body =
  Client.post
    ~body:(Cohttp_lwt.Body.of_string body)
    (Uri.of_string (Printf.sprintf "http://%s:%d/command" leader_host port))
  >>= fun (resp, body) ->
  body |> Cohttp_lwt.Body.to_string >|= fun body ->
  let status_code = resp |> Response.status in
  (status_code, body)


let handle_or_proxy (oraft : Oraft.t) body f =
  let state = oraft.current_state () in
  match (state.mode, state.leader) with
  | LEADER, _ -> f ()
  | _, Some node -> redirect_to_leader node.host node.port body
  | _ -> Lwt.return (`Internal_server_error, "")


let server port (oraft : Oraft.t) =
  let callback _conn req body =
    let meth = req |> Request.meth in
    let path = req |> Request.uri |> Uri.path in
    match (meth, path) with
    | `POST, "/command" ->
        ( body |> Cohttp_lwt.Body.to_string >>= fun request_body ->
          let cmd, args = parse_command request_body in
          match cmd with
          | "SET" ->
              oraft.post_command request_body >>= fun result ->
              Lwt.return
                (if result then (`OK, "") else (`Internal_server_error, ""))
          | "INCR" ->
              oraft.post_command request_body >>= fun result ->
              Lwt.return
                (if result then (`OK, "") else (`Internal_server_error, ""))
          | "CAS" ->
              Lwt_mutex.with_lock lock (fun () ->
                  handle_or_proxy oraft request_body (fun () ->
                      let k = List.nth args 0 in
                      let expected = List.nth args 1 in
                      match Hashtbl.find_opt kvs k with
                      | Some x when x = expected ->
                          oraft.post_command request_body >>= fun result ->
                          Lwt.return
                            ( if result
                            then (`OK, "")
                            else (`Internal_server_error, "")
                            )
                      | Some _ -> Lwt.return (`Conflict, "")
                      | None -> Lwt.return (`Not_found, "")))
          | "GET" ->
              handle_or_proxy oraft request_body (fun () ->
                  let k = List.nth args 0 in
                  Lwt.return
                    ( match Hashtbl.find_opt kvs k with
                    | Some x -> (`OK, x)
                    | None -> (`Not_found, "")
                    ))
          | _ -> Lwt.return (`Bad_request, "") )
        >>= fun (status_code, response_body) ->
        Server.respond_string ~status:status_code ~body:response_body ()
    | _ -> Server.respond_string ~status:`Not_found ~body:"" ()
  in
  Server.create ~mode:(`TCP (`Port port)) (Server.make ~callback ())


let main =
  let port, conf_file =
    let args = Core.Sys.get_argv () in
    if args |> Array.length >= 3
    then (args.(1) |> int_of_string, args.(2))
    else failwith "Config file isn't specified"
  in
  let oraft = oraft conf_file in
  let server = server port oraft in
  Lwt.join [ server; oraft.process ] |> Lwt_main.run
