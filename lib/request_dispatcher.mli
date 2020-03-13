type key = Cohttp.Code.meth * string

type converter = Yojson.Safe.t -> (Params.request, string) Core.Result.t

type response = (Cohttp.Response.t * Cohttp_lwt__.Body.t) Lwt.t

type processor = Params.request -> response

val create :
  port:int ->
  logger:Logger.t ->
  lock:Lwt_mutex.t ->
  table:(key, converter * processor) Hashtbl.t ->
  unit Lwt.t * unit Lwt.u
