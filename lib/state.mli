(** Persistent state on all servers:
    (Updated on stable storage before responding to RPCs) *)
module PersistentState : sig
  type t

  val show : t -> string

  val to_yojson : t -> Yojson.Safe.t

  val of_yojson : Yojson.Safe.t -> t Ppx_deriving_yojson_runtime.error_or

  val load : state_dir:string -> t

  val save : t -> unit

  val log : t -> logger:Logger.t -> unit

  val current_term : t -> int

  val update_current_term : t -> term:int -> unit

  val increment_current_term : t -> unit

  val detect_new_leader : t -> logger:Logger.t -> other_term:int -> bool

  val detect_old_leader : t -> logger:Logger.t -> other_term:int -> bool

  val voted_for : t -> int option

  val set_voted_for : t -> logger:Logger.t -> voted_for:int option -> unit
end

(** Persistent log state *)
module PersistentLogEntry : sig
  type t = { term : int; index : int; data : string }

  val pp : Format.formatter -> t -> unit

  val show : t -> string

  val to_yojson : t -> Yojson.Safe.t

  val of_yojson : Yojson.Safe.t -> t Ppx_deriving_yojson_runtime.error_or

  val from_string : 'a -> 'a

  val log : t -> logger:Logger.t -> unit
end

module PersistentLog : sig
  type t

  val show : t -> string

  val load : state_dir:string -> t

  val to_string_list : t -> string list

  val log : t -> logger:Logger.t -> unit

  val get : t -> int -> PersistentLogEntry.t option

  val get_exn : t -> int -> PersistentLogEntry.t

  val last_index : t -> int

  val last_log : t -> PersistentLogEntry.t

  val append_to_file : t -> log:PersistentLogEntry.t -> unit

  val append :
    t -> term:int -> start:int -> entries:PersistentLogEntry.t list -> unit
end

(** Volatile state on all servers *)
module VolatileState : sig
  type t

  val show : t -> string

  val create : unit -> t

  val log : t -> logger:Logger.t -> unit

  val update_commit_index : t -> int -> unit

  val update_last_applied : t -> int -> unit

  val commit_index : t -> int

  val detect_higher_commit_index : t -> logger:Logger.t -> other:int -> bool

  val last_applied : t -> int

  val apply_logs : t -> logger:Logger.t -> f:(int -> unit) -> unit

  (** These are customized functions that aren't shown in the paper *)
  val mode : t -> Base.mode

  val update_mode : t -> logger:Logger.t -> Base.mode -> unit

  val leader_id : t -> int option

  val update_leader_id : t -> logger:Logger.t -> int -> unit
end

(** Volatile state on leaders:
  * (Reinitialized after election) *)
module VolatileStateOnLeader : sig
  type peer

  type t = peer list

  val show : t -> string

  val create : n:int -> last_log_index:int -> peer list

  val log : t -> logger:Logger.t -> unit

  val get : 'a list -> int -> 'a

  val set_next_index : peer list -> int -> int -> unit

  val set_match_index : peer list -> logger:Logger.t -> int -> int -> unit

  val show_nth_peer : t -> int -> string

  val next_index : t -> int -> int

  val match_index : t -> int -> int
end

type common = {
  persistent_state : PersistentState.t;
  persistent_log : PersistentLog.t;
  volatile_state : VolatileState.t;
}

val log : common -> logger:Logger.t -> unit

type leader = {
  common : common;
  volatile_state_on_leader : VolatileStateOnLeader.t;
}

val log_leader : leader -> logger:Logger.t -> unit
