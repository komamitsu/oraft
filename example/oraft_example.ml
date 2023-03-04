open Lwt
open Cohttp_lwt_unix

let kvs = Hashtbl.create 64

let ids = Hashtbl.create 4096

let print_log s =
  (*
  let now = Core.Time.to_string (Core.Time.now ()) in
  Printf.printf "%s - %s\n" now s;
  flush stdout
  *)
  print_endline s

let parse_command s =
  (* ID CMD ARG0 ARG1 ... *)
  let parts = Core.String.split ~on:' ' s in
  match parts with
    | id::rest -> (
      match rest with
      |  cmd::args -> (id, cmd, args)
      |  _ -> failwith "Unexpected format"
    )
    | _ -> failwith "Unexpected format"

let with_flush_stdout f =
  f ();
  Core.Out_channel.flush stdout

let remember_id id =
  Hashtbl.replace ids id true

let exec_with_dedup label id args f =
  match Hashtbl.find_opt ids id with
  | Some _ ->
    print_log @@
      Printf.sprintf "???? duplicated id (%s) : id=%s, args=%s ????" label id (String.concat " " args)
  | None -> (
    let result = f () in
    remember_id id;
    result
  )

let kvs_set id args =
  exec_with_dedup "SET" id args (fun () ->
    Hashtbl.replace kvs (List.nth args 0) (List.nth args 1)
  )


let kvs_incr id args =
  exec_with_dedup "INCR" id args (fun () ->
    let k = List.nth args 0 in
    let v =
      match Hashtbl.find_opt kvs k with
      | Some x -> (
          match int_of_string_opt x with Some i -> i | None -> 0
        )
      | None -> 0
    in
    let diff = List.nth args 1 in
    let incremented = string_of_int (v + int_of_string(diff)) in
    Hashtbl.replace kvs k incremented;
  )


let oraft conf_file =
  Oraft.start ~conf_file ~apply_log:(fun ~node_id ~log_index ~log_data ->
      with_flush_stdout (fun () ->
        print_log @@
          Printf.sprintf "<<<< %d: APPLY(%d) : %s >>>>" node_id log_index log_data
      );
      let id, cmd, args = parse_command log_data in
      match cmd with
      | "SET" -> kvs_set id args
      | "INCR" -> kvs_incr id args
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
          let _, cmd, args = parse_command request_body in
          match cmd with
          | "SET" ->
              oraft.post_command request_body >>= fun result ->
              Lwt.return
                (if result then (`OK, "") else (`Internal_server_error, ""))
          | "INCR" ->
              oraft.post_command request_body >>= fun result ->
              Lwt.return
                (if result then (`OK, "") else (`Internal_server_error, ""))
          | "GET" ->
              handle_or_proxy oraft request_body (fun () ->
                  let k = List.nth args 0 in
                  Lwt.return
                    ( match Hashtbl.find_opt kvs k with
                    | Some x -> (`OK, x)
                    | None -> (`Not_found, "")
                    ))
          | "KEYS" ->
            let key_seq = Hashtbl.to_seq_keys kvs in
            let keys = Seq.fold_left (fun acc x -> x::acc) [] key_seq in
            let csv = String.concat "," keys in
              handle_or_proxy oraft request_body (fun () -> Lwt.return (`OK, csv))
          | _ -> Lwt.return (`Bad_request, "") )
        >>= fun (status_code, response_body) ->
        Server.respond_string ~status:status_code ~body:response_body ()
    | _ -> Server.respond_string ~status:`Not_found ~body:"" ()
  in
  Server.create ~mode:(`TCP (`Port port)) (Server.make ~callback ())


let _ =
  let port, conf_file =
    let args = Core.Sys.get_argv () in
    if args |> Array.length >= 3
    then (args.(1) |> int_of_string, args.(2))
    else failwith "Config file isn't specified"
  in
  let oraft = oraft conf_file in
  let server = server port oraft in
  Lwt.join [ server; oraft.process ] |> Lwt_main.run
