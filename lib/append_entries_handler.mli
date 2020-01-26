val handle :
  state:State.common ->
  logger:Logger.t ->
  apply_log:(int -> string -> unit) ->
  cb_valid_request:(unit -> unit) ->
  cb_new_leader:(unit -> unit) ->
  param:Params.append_entries_request ->
  (Cohttp.Response.t * Cohttp_lwt__.Body.t) Lwt.t
