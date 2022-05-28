type t = {
  conf : Conf.t;
  logger : Logger.t;
  lock : Lwt_mutex.t;
  dispatcher : Request_dispatcher.t;
}

let create ~(conf:Conf.t) =
  let logger = Logger.create ~node_id:conf.node_id ~output_path:conf.log_file
        ~level:conf.log_level in
  let lock = Lwt_mutex.create () in
  let dispatcher = Request_dispatcher.create ~port:(Conf.my_node conf).port ~logger:logger ~lock in
  {
    conf;
    logger;
    lock;
    dispatcher;
  }

