type level = TRACE | DEBUG | INFO | WARN | ERROR

type t

val create :
  node_id:int ->
  output_path:string ->
  level:string ->
  t

val mode : t -> mode:Base.mode option -> unit

val debug : t -> string -> unit

val info : t -> string -> unit

val warn : t -> string -> unit

val error : t -> string -> unit
