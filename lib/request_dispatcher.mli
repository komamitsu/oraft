  type key = Cohttp.Code.meth * string

  type converter =
      Yojson.Safe.t -> (Params.request, string) Core.Result.t

  type response = (Cohttp.Response.t * Cohttp_lwt__.Body.t) Lwt.t

  type processor = Params.request -> response

  val create :
    int ->
    Lock.t ->
    Logger.t ->
    (key, converter * processor) Hashtbl.t -> unit Lwt.t * unit Lwt.u
