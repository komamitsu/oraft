type t

val update : t -> unit

val start : t -> on_stop:(unit -> 'a) -> 'a Lwt.t

val create : logger:Logger.t -> timeout_millis:int -> t

val stop : t -> unit
