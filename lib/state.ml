open Core

(** Persistent state on all servers:
    (Updated on stable storage before responding to RPCs) *)
module PersistentState = struct
  type state = { mutable current_term : int; mutable voted_for : int option }
  [@@deriving yojson]
  (** Just persistent format *)

  type t = {
    path : string;
        (** latest term server has seen (initialized to 0 
     *  on first boot, increases monotonically) *)
    mutable current_term : int;
        (** candidateId that received vote in current term (or null if none) *)
    mutable voted_for : int option;
  }
  [@@deriving show, yojson]

  let load state_dir =
    let path = Filename.concat state_dir "state.json" in
    match Sys.file_exists path with
    | `Yes -> (
        match Yojson.Safe.from_file path |> state_of_yojson with
        | Ok state ->
            {
              path;
              current_term = state.current_term;
              voted_for = state.voted_for;
            }
        | Error _ -> { path; current_term = 0; voted_for = None } )
    | _ -> { path; current_term = 0; voted_for = None }

  let save t =
    let state = { current_term = t.current_term; voted_for = t.voted_for } in
    Out_channel.write_all t.path
      ~data:(state_to_yojson state |> Yojson.Safe.to_string)

  let log logger t = Logger.debug logger ("PersistentState : " ^ show t)

  let current_term t = t.current_term

  let update_current_term t term =
    t.current_term <- term;
    save t

  let increment_current_term t =
    t.current_term <- t.current_term + 1;
    save t

  let detect_new_leader logger t other_term =
    if other_term > t.current_term
    then (
      Logger.info logger
        (Printf.sprintf "Detected new leader's term: %d, state.term: %d"
           other_term t.current_term);
      true )
    else false

  let detect_old_leader logger t other_term =
    if other_term < t.current_term
    then (
      Logger.info logger
        (Printf.sprintf "Detected old leader's term: %d, state.term: %d"
           other_term t.current_term);
      true )
    else false

  let voted_for t = t.voted_for

  let set_voted_for logger t voted_for =
    let to_string = function
      | Some x -> "Some " ^ string_of_int x
      | None -> "None"
    in
    Logger.info logger
      (Printf.sprintf "Setting voted_for from %s to %s" (to_string t.voted_for)
         (to_string voted_for));
    t.voted_for <- voted_for
end

(** Persistent log state *)
module PersistentLogEntry = struct
  type t = { term : int; index : int; data : string } [@@deriving show, yojson]

  let empty = { term = 0; index = 0; data = "" }

  let from_string s = s

  let log logger t = Logger.debug logger ("PersistentLogEntry : " ^ show t)
end

module PersistentLog = struct
  type t = {
    path : string;  (** Just for convenience *)
    mutable last_index : int;
        (** log entries; each entry contains command for state machine,
     *  and term when entry was received by leader (first index is 1) *)
    mutable list : PersistentLogEntry.t list;
  }
  [@@deriving show, yojson]

  let load state_dir =
    let path = Filename.concat state_dir "log.jsonl" in
    match Sys.file_exists path with
    | `Yes ->
        let lines =
          In_channel.with_file path ~f:(fun ch -> In_channel.input_lines ch)
        in
        let cur = ref 0 in
        let logs =
          List.map
            ~f:(fun s ->
              match
                Yojson.Safe.from_string s |> PersistentLogEntry.of_yojson
              with
              | Ok log ->
                  if log.index < !cur
                  then
                    failwith
                      (Printf.sprintf
                         "Unexpected lower index in logs. cur:%d, log:%s" !cur
                         (PersistentLogEntry.show log));
                  cur := log.index;
                  log
              | Error err ->
                  failwith (Printf.sprintf "Failed to parse JSON: %s" err))
            lines
        in
        { path; last_index = !cur; list = logs }
    | _ -> { path; last_index = 0; list = [] }

  let to_string_list t = List.map t.list ~f:PersistentLogEntry.show

  let log logger t =
    Logger.debug logger "PersistentLog : ";
    to_string_list t |> List.iter ~f:(Logger.debug logger)

  let get t index = List.nth t.list (index - 1)

  let get_exn t index = List.nth_exn t.list (index - 1)

  let last_index t = t.last_index

  let last_log t =
    match get t (last_index t) with
    | Some last_log -> last_log
    | None -> PersistentLogEntry.empty

  let append_to_file t log =
    Out_channel.with_file t.path ~append:true ~f:(fun ch ->
        Out_channel.output_lines ch
          [ PersistentLogEntry.to_yojson log |> Yojson.Safe.to_string ])

  let append t term start entries =
    let rec update_ xs i entries =
      if List.length entries = 0
      then xs
      else
        (* New entry if needed *)
        let entry : PersistentLogEntry.t =
          { term; index = i + 1; data = List.hd_exn entries }
        in
        t.last_index <- i + 1;
        let current, rest =
          let tl_entries = List.tl_exn entries in
          if i < List.length t.list
          then
            let x = List.nth_exn t.list i in
            (* Raft's log index is 1 origin *)
            if i < start - 1
            then (x, entries)
            else if x.term = term
            then (x, tl_entries)
            else (entry, tl_entries)
          else (entry, tl_entries)
        in
        if phys_equal current entry then append_to_file t entry;
        update_ (current :: xs) (i + 1) rest
    in
    let rev_list = update_ [] 0 entries in
    t.list <- List.rev rev_list
end

(** Volatile state on all servers *)
module VolatileState = struct
  type t = {
    (** index of highest log entry known to be
     *  committed (initialized to 0, increases monotonically) *)
    mutable commit_index : int;
        (** index of highest log entry applied to state
     *  machine (initialized to 0, increases monotonically) *)
    mutable last_applied : int;
  }
  [@@deriving show]

  let create () = { commit_index = 0; last_applied = 0 }

  let log logger t = Logger.debug logger ("VolatileState: " ^ show t)

  let update_commit_index t i = t.commit_index <- i

  let update_last_applied t i = t.last_applied <- i

  let commit_index t = t.commit_index

  let detect_higher_commit_index logger t other =
    if other > t.commit_index
    then (
      Logger.debug logger
        (Printf.sprintf "Leader commit(%d) is higher than state.term(%d)" other
           t.commit_index);
      true )
    else false

  let last_applied t = t.last_applied

  let apply_logs t f =
    let rec loop () =
      if t.last_applied < t.commit_index
      then (
        let i = t.last_applied + 1 in
        f i;
        update_last_applied t i;
        loop () )
    in
    loop ()
end

(** Volatile state on leaders:
  * (Reinitialized after election) *)
module VolatileStateOnLeader = struct
  type peer = {
    (** for each server, index of the next log entry to send
     *  to that server (initialized to leader last log index + 1) *)
    mutable next_index : int;
        (** for each server, index of highest log entry known to be replicated on server
     *  (initialized to 0, increases monotonically) *)
    mutable match_index : int;
  }
  [@@deriving show]

  type t = peer list [@@deriving show]

  let create n last_log_index =
    List.init n ~f:(fun _ ->
        { next_index = last_log_index + 1; match_index = 0 })

  let log logger t = Logger.debug logger ("VolatileStateOnLeader: " ^ show t)

  let get t i = List.nth_exn t i

  let set_next_index t i x = (List.nth_exn t i).next_index <- x

  let show_nth_peer t i = get t i |> show_peer

  let next_index t i = (get t i).next_index
end

type common = {
  persistent_state : PersistentState.t;
  persistent_log : PersistentLog.t;
  volatile_state : VolatileState.t;
}

let log logger t =
  PersistentState.log logger t.persistent_state;
  PersistentLog.log logger t.persistent_log;
  VolatileState.log logger t.volatile_state

type leader = {
  common : common;
  volatile_state_on_leader : VolatileStateOnLeader.t;
}

let log_leader logger t =
  log logger t.common;
  VolatileStateOnLeader.log logger t.volatile_state_on_leader