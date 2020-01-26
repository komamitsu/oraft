val handle :
  state:State.common ->
  logger:Logger.t ->
  cb_valid_request:(unit -> unit) ->
  cb_new_leader:(unit -> unit) ->
  param:Params.request_vote_request ->
  (Cohttp.Response.t * Cohttp_lwt__.Body.t) Lwt.t
