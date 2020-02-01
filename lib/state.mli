(** Persistent state on all servers:
    (Updated on stable storage before responding to RPCs) *)
module PersistentState :
  sig
    type t

    val show : t -> string

    val to_yojson : t -> Yojson.Safe.t

    val of_yojson : Yojson.Safe.t -> t Ppx_deriving_yojson_runtime.error_or

    val load : string -> t

    val save : t -> unit

    val log : Logger.t -> t -> unit

    val current_term : t -> int

    val update_current_term : t -> int -> unit

    val increment_current_term : t -> unit

    val detect_new_leader :
      Logger.t -> t -> int -> bool

    val detect_old_leader :
      Logger.t -> t -> int -> bool

    val voted_for : t -> int option

    val set_voted_for : Logger.t -> t -> int option -> unit
  end

(** Persistent log state *)
module PersistentLogEntry :
  sig
    type t = { term : int; index : int; data : string; }

    val show : t -> string

    val to_yojson : t -> Yojson.Safe.t

    val of_yojson : Yojson.Safe.t -> t Ppx_deriving_yojson_runtime.error_or

    val from_string : 'a -> 'a

    val log : Logger.t -> t -> unit
  end

module PersistentLog :
  sig
    type t

    val show : t -> string

    val to_yojson : t -> Yojson.Safe.t

    val of_yojson : Yojson.Safe.t -> t Ppx_deriving_yojson_runtime.error_or

    val load : string -> t

    val to_string_list : t -> string list

    val log : Logger.t -> t -> unit

    val get : t -> int -> PersistentLogEntry.t option

    val get_exn : t -> int -> PersistentLogEntry.t

    val last_index : t -> int

    val last_log : t -> PersistentLogEntry.t

    val append_to_file : t -> PersistentLogEntry.t -> unit

    val append : t -> int -> int -> string list -> unit
  end

(** Volatile state on all servers *)
module VolatileState :
  sig
    type t

    val show : t -> string

    val create : unit -> t

    val log : Logger.t -> t -> unit

    val update_commit_index : t -> int -> unit

    val update_last_applied : t -> int -> unit

    val commit_index : t -> int

    val detect_higher_commit_index :
      Logger.t -> t -> int -> bool

    val last_applied : t -> int

    val apply_logs : Logger.t -> t -> (int -> unit) -> unit
  end

(** Volatile state on leaders:
  * (Reinitialized after election) *)
module VolatileStateOnLeader :
  sig
    type peer

    type t = peer list

    val show : t -> string

    val create : int -> int -> peer list

    val log : Logger.t -> t -> unit

    val get : 'a list -> int -> 'a

    val set_next_index : peer list -> int -> int -> unit

    val show_nth_peer : t -> int -> string 

    val next_index : t -> int -> int
  end

type common = {
  persistent_state : PersistentState.t;
  persistent_log : PersistentLog.t;
  volatile_state : VolatileState.t;
}

val log : Logger.t -> common -> unit

type leader = {
  common : common;
  volatile_state_on_leader : VolatileStateOnLeader.t;
}

val log_leader : Logger.t -> leader -> unit
