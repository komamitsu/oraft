type t

val run :
  conf:Conf.t ->
  apply_log:Base.apply_log ->
  state:State.common ->
  (Base.mode Lwt.t, string) result
