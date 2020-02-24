type leader_node = {
  host : string; port : int;
}

type current_state = {
  mode : Base.mode;
  term : int;
  leader : leader_node option;
}

type t = {
  conf : Conf.t;
  process : unit Lwt.t;
  post_command : string -> bool Lwt.t;
  current_state : unit -> current_state;
}

val start : conf_file:string -> apply_log:(int -> string -> unit) -> t
