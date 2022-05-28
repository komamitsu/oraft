type t

val init : resource:Resource.t -> apply_log:Base.apply_log -> state:State.common -> t

val run : t -> unit -> Base.mode Lwt.t
