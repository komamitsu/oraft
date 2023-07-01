let main ~conf_file =
  let oraft =
    Oraft.start ~conf_file ~apply_log:(fun ~node_id ~log_index ~log_data ->
        Printf.printf
          "Received %d th command from node_id:%d. Maybe you'd better take care of '%s' instead of just printing\n"
          log_index node_id log_data;
        flush stdout
    )
  in
  let rec loop () =
    let%lwt s = Lwt_io.read_line Lwt_io.stdin in
    let%lwt result = oraft.post_command s in
    let%lwt _ = Lwt_io.printl (if result then "OK" else "ERR") in
    loop ()
  in
  Lwt.join [ loop (); oraft.process ] |> Lwt_main.run


let () =
  let open Command.Let_syntax in
  Command.basic ~summary:"Simple example application for ORaft"
    [%map_open
      let config =
        flag "config" (required string) ~doc:"CONFIG Config file path"
      in
      fun () -> ignore (main ~conf_file:config)]
  |> Command_unix.run
