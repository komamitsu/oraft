type t
type lock

val create :
  conf:Conf.t ->
  state:State.leader ->
  logger:Logger.t ->
  node_id:int ->
  step_down:(unit -> unit) ->
  t

val stop : t -> unit
val wait_append_entries_response : t -> log_index:int -> lock
