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


let oraft conf_file =
  Oraft.start conf_file ~apply_log:(fun i s ->
      with_flush_stdout (fun () ->
          Printf.printf "<<<<<<<<<<<<<<<< APPLY(%d) : %s >>>>>>>>>>>>>>>>\n" i s);
      let cmd, args = parse_command s in
      match cmd with
      | "SET" -> Hashtbl.replace kvs (List.nth args 0) (List.nth args 1)
      | _ ->
          ();
          Core.Out_channel.flush Core.Out_channel.stdout)


let server port (oraft : Oraft.t) =
  let callback _conn req body =
    let meth = req |> Request.meth in
    let path = req |> Request.uri |> Uri.path in
    match (meth, path) with
    | `POST, "/command" ->
        body |> Cohttp_lwt.Body.to_string
        >>= fun request_body ->
        oraft.post_command request_body
        >>= fun result ->
        let status_code, response_body =
          if result
          then (
            let cmd, args = parse_command request_body in
            match cmd with
            | "SET" ->
                Hashtbl.replace kvs (List.nth args 0) (List.nth args 1);
                (`OK, "")
            | "GET" -> (
                match Hashtbl.find_opt kvs (List.nth args 0) with
                | Some x -> (`OK, x)
                | None -> (`Not_found, "")
              )
            | _ -> (`Bad_request, "")
          )
          else (`Internal_server_error, "")
        in
        Server.respond_string ~status:status_code ~body:response_body ()
    | _ -> Server.respond_string ~status:`Not_found ~body:"" ()
  in
  Server.create ~mode:(`TCP (`Port port)) (Server.make ~callback ())


let main =
  let port, conf_file =
    let args = Core.Sys.get_argv () in
    if args |> Array.length >= 3
    then
      args.(1) |> int_of_string, args.(2)
    else failwith "Config file isn't specified"
  in
  let oraft = oraft conf_file in
  let server = server port oraft in
  Lwt.join [ server; oraft.process ] |> Lwt_main.run
