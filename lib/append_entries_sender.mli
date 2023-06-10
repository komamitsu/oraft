type t

val create :
  conf:Conf.t ->
  state:State.leader ->
  logger:Logger.t ->
  step_down:(unit -> unit) ->
  t

val stop : t -> unit
val wait_append_entries_response : t -> log_index:int -> unit Lwt.t
val wait_termination : t -> unit Lwt.t
