type level = TRACE | DEBUG | INFO | WARN | ERROR
type t

val create :
  node_id:int ->
  ?mode:Base.mode ->
  ?output_path:string ->
  level:string ->
  unit ->
  t

val debug : t -> loc:string -> string -> unit
val info : t -> loc:string -> string -> unit
val warn : t -> loc:string -> string -> unit
val error : t -> loc:string -> string -> unit
