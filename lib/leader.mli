type t

val init : conf:Conf.t -> apply_log:Base.apply_log -> state:State.common -> t

val run : t -> unit -> Base.mode Lwt.t
