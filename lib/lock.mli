type t

val create : unit -> t

val with_lock : t -> (unit -> 'a) -> 'a
