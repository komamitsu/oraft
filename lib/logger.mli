type level = TRACE | DEBUG | INFO | WARN | ERROR

type t

val create : int -> Base.mode option -> string -> string -> t

val debug : t -> string -> unit

val info : t -> string -> unit

val warn : t -> string -> unit

val error : t -> string -> unit
