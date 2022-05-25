type key = Cohttp.Code.meth * string

type converter = Yojson.Safe.t -> (Params.request, string) Core.Result.t

type response = (Cohttp.Response.t * Cohttp_lwt__.Body.t) Lwt.t

type processor = Params.request -> response

type handler = (key, converter * processor) Stdlib.Hashtbl.t

type t

val create :
  port:int ->
  logger:Logger.t ->
  lock:Lwt_mutex.t ->
  t

val set_handler : t -> handler:handler -> unit

val disable_handler : t -> unit

