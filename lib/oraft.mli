type t = {
  conf : Conf.t;
  process : unit Lwt.t;
  post_command : string -> bool Lwt.t;
}

val start : string -> apply_log:(int -> string -> unit) -> t
