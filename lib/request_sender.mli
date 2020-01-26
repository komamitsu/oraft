val post :
  node_id:int ->
  logger:Logger.t ->
  url_path:string ->
  request_json:Yojson.Safe.t ->
  converter:(Yojson.Safe.t ->
             (Params.response, string) Core.Result.t) -> Base.node -> Params.response option Lwt.t
