type level = TRACE | DEBUG | INFO | WARN | ERROR

type t

val create :
  node_id:int ->
  ?mode:Base.mode ->
  ?output_path:string ->
  level:string ->
  unit ->
  t

val debug : t -> string -> unit

val info : t -> string -> unit

val warn : t -> string -> unit

val error : t -> string -> unit
