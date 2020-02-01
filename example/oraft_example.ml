open Lwt
open Cohttp_lwt_unix

let kvs = Hashtbl.create 64

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


let oraft conf_file =
  Oraft.start ~conf_file ~apply_log:(fun i s ->
      with_flush_stdout (fun () ->
          Printf.printf "<<<<<<<<<<<<<<<< APPLY(%d) : %s >>>>>>>>>>>>>>>>\n" i s);
      let cmd, args = parse_command s in
      match cmd with "SET" -> kvs_set args | "INCR" -> kvs_incr args | _ -> ())


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
          | "GET" ->
              Lwt.return
                ( match Hashtbl.find_opt kvs (List.nth args 0) with
                | Some x -> (`OK, x)
                | None -> (`Not_found, "")
                )
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
