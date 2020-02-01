type t = {
  conf : Conf.t;
  process : unit Lwt.t;
  post_command : string -> bool Lwt.t;
}

val start : conf_file:string -> apply_log:(int -> string -> unit) -> t
