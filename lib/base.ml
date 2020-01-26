type mode = FOLLOWER | CANDIDATE | LEADER [@@deriving show]

type node = { id : int; host : string; port : int }
[@@deriving show, yojson { exn = true }]
