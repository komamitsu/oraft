type t

val init :
  conf:Conf.t ->
  lock:Lock.t ->
  apply_log:(int -> string -> unit) -> state:State.common -> t

val run : t -> unit -> Base.mode Lwt.t
