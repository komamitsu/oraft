type t

val update : t -> unit

val start : t -> (unit -> 'a) -> 'a Lwt.t

val create : Logger.t -> int -> t

val stop : t -> unit
