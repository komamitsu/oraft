type mode = FOLLOWER | CANDIDATE | LEADER [@@deriving show]

type node = { id : int; host : string; port : int; app_port : int }
[@@deriving show, yojson { exn = true }]

type apply_log = node_id:int -> log_index:int -> log_data:string -> unit
