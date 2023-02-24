open Core
open Printf

(* Persistent state on all servers:
    (Updated on stable storage before responding to RPCs) *)
module PersistentState = struct
  type state = { current_term : int; voted_for : int option }
  [@@deriving yojson]

  (* Just persistent format *)

  type t = {
    path : string;
    (* latest term server has seen (initialized to 0 
     * on first boot, increases monotonically) *)
    mutable current_term : int;
    (* candidateId that received vote in current term (or null if none) *)
    mutable voted_for : int option;
  }
  [@@deriving show, yojson]

  let load ~state_dir =
    let path = Filename.concat state_dir "state.json" in
    match Sys_unix.file_exists path with
    | `Yes -> (
        match Yojson.Safe.from_file path |> state_of_yojson with
        | Ok state ->
            {
              path;
              current_term = state.current_term;
              voted_for = state.voted_for;
            }
        | Error _ -> { path; current_term = 0; voted_for = None }
      )
    | _ -> { path; current_term = 0; voted_for = None }

  let save t =
    let state = { current_term = t.current_term; voted_for = t.voted_for } in
    Out_channel.write_all t.path
      ~data:(state_to_yojson state |> Yojson.Safe.to_string)

  let log t ~logger = Logger.debug logger ("PersistentState : " ^ show t)

  let voted_for t = t.voted_for

  let set_voted_for t ~logger ~voted_for =
    let to_string = function
      | Some x -> "Some " ^ string_of_int x
      | None -> "None"
    in
    Logger.info logger
      (sprintf "Setting voted_for from %s to %s" (to_string t.voted_for)
         (to_string voted_for));
    t.voted_for <- voted_for;
    save t

  let current_term t = t.current_term

  let update_current_term t ~term =
    t.current_term <- term;
    save t

  let increment_current_term t =
    t.current_term <- t.current_term + 1;
    save t

  let detect_same_term t ~logger ~other_term =
    if other_term = t.current_term
    then (
      Logger.info logger
        (sprintf "Detected the same term: %d, state.term: %d. Stepping down" other_term
           t.current_term);
      set_voted_for t ~logger ~voted_for:None;
      true
    )
    else false

  let detect_newer_term t ~logger ~other_term =
    if other_term > t.current_term
    then (
      Logger.info logger
        (sprintf "Detected newer term: %d, state.term: %d. Stepping down" other_term
           t.current_term);
      update_current_term t ~term:other_term;
      t.voted_for <- None;
      save t;
      true
    )
    else false

  let detect_old_leader t ~logger ~other_term =
    if other_term < t.current_term
    then (
      Logger.info logger
        (sprintf "Detected old leader's term: %d, state.term: %d" other_term
           t.current_term);
      true
    )
    else false
end

(* Persistent log state *)
module PersistentLogEntry = struct
  type t = { term : int; index : int; data : string } [@@deriving show, yojson]

  let empty = { term = 0; index = 0; data = "" }

  let create ~index ~term ~data = { term; index; data }

  let from_string s = s

  let log t ~logger = Logger.debug logger ("PersistentLogEntry : " ^ (show t))
end

module PersistentLog = struct
  type t = {
    path : string;
    db : Sqlite3.db;
    logger : Logger.t;
  }

  let exec_sql ~db ~logger ?(cb = (fun _ _ -> ())) sql =
    let rc = Sqlite3.exec db ~cb sql in
    match rc with
    | OK -> ()
    | _ -> Logger.error logger (Printf.sprintf "SQL execution failed. sql:[%s]. rc:[%s]" sql (Sqlite3.Rc.to_string rc))

  let setup_db ~path ~logger =
    let db = Sqlite3.db_open path in
    exec_sql ~db ~logger ~cb:(fun row _ ->
      let count = Array.get row 0 in
      match count with
      | Some "0" -> exec_sql ~db ~logger
        "create table if not exists oraft_log (\"index\" int primary key, \"term\" int, \"data\" text)"
      | Some "1" -> ()
      | _ -> Logger.error logger "Failed to check table 'oraft_log'"
    ) "select count() from sqlite_schema where name = 'oraft_log'";
    db

  let fetch_from_row ~logger ~row ~col_index =
    match (Array.get row col_index) with
    | Some x -> x
    | None -> (Logger.error logger (Printf.sprintf "Found unexpected empty value. index:%d" col_index); "0")

  let log_from_row ~logger ~row =
    (* FIXME: This depends on the order of the SELECT statement *)
    let index = int_of_string (fetch_from_row ~logger ~row ~col_index:0) in
    let term = int_of_string (fetch_from_row ~logger ~row ~col_index:1) in
    let data = fetch_from_row ~logger ~row ~col_index:2 in
    PersistentLogEntry.create ~index ~term ~data
  
(*
  let check_records db =
    let last_index = ref 1 in
    let logs = ref [] in
    (* TODO: Check if the index increases sequentially *)
    exec_sql db ~cb:(fun row _ ->
      let log = log_from_row row in
      let index = log.index in
      last_index := index;
      logs := log :: !logs
    )
    "select index, term, data from oraft_log order by id";
    (!last_index, !logs)
*)

  let load ~state_dir ~logger =
    let path = Filename.concat state_dir "log.db" in
    let db = setup_db ~path ~logger in
    { db; path; logger }

  let last_index t = 
    let count = ref None in
    exec_sql ~db:t.db ~logger:t.logger ~cb:(fun row _ ->
      count := Some (int_of_string (fetch_from_row ~logger:t.logger ~row ~col_index:0))
    )
    "select count(1) from oraft_log";
    match !count with
    | Some x -> x + 1  (* Raft's log index is 1 origin *)
    | _ -> (Logger.error t.logger "Failed to get the total record count"; 0)

  let fetch t ?(asc = true) n =
    let order = if asc then "asc" else "desc" in
    let records = ref [] in
    exec_sql ~db:t.db ~logger:t.logger ~cb:(fun row _ ->
      let r = log_from_row ~logger:t.logger ~row in
      records := r::!records
    )
    (* TODO: Use prepared statement *)
    (Printf.sprintf "select \"index\", \"term\", \"data\" from oraft_log order by \"index\" %s limit %d" order n);
    !records

  let show t =
    let entries = fetch t ~asc:false 3 in
    sprintf
      "{PersistentLog.path = \"%s\"; last_index = %d; last_entries = [%s]}"
      t.path
      (last_index t)
      (String.concat ~sep:", " (List.map entries ~f:PersistentLogEntry.show))

  let log t ~logger = Logger.debug logger ("PersistentLog: " ^ (show t))

  let get t i =
    let record = ref None in
    exec_sql ~db:t.db ~logger:t.logger ~cb:(fun row _ ->
      record := Some (log_from_row ~logger:t.logger ~row)
    )
    (* TODO: Use prepared statement *)
    (Printf.sprintf "select \"index\", \"term\", \"data\" from oraft_log where \"index\" = %d" i);
    !record

  let get_exn t i =
    match get t i with
    | Some x -> x
    | _ -> (Logger.error t.logger (Printf.sprintf "Failed to get the record. index=%d" i); PersistentLogEntry.empty)

  let set t (entry:PersistentLogEntry.t) =
    exec_sql ~db:t.db ~logger:t.logger ~cb:(fun _ _ -> ())
    (* TODO: Use prepared statement *)
    (* TODO: Check updated record count *)
    (Printf.sprintf "update oraft_log set \"term\" = %d, \"data\" = '%s' where \"index\" = %d" entry.term entry.data entry.index)

  let add t (entry:PersistentLogEntry.t) =
    (* Maybe assertion of the previous entry would be good *)
    exec_sql ~db:t.db ~logger:t.logger ~cb:(fun _ _ -> ())
    (* TODO: Use prepared statement *)
    (Printf.sprintf "insert into oraft_log (\"index\", \"term\", \"data\") values (%d, %d, '%s')" entry.index entry.term entry.data)

  let last_log t =
    (* FIXME *)
    match get t (last_index t) with
    | Some last_log -> last_log
    | None -> PersistentLogEntry.empty

  let append t ~start ~entries =
    let rec loop i (entries : PersistentLogEntry.t list) =
      if List.length entries > 0
      then (
        (* New entry if needed *)
        let entry_from_param = List.hd_exn entries in
        let rest_of_entries_from_param = List.tl_exn entries in
        (* TODO: Revisit here *)
        let entry : PersistentLogEntry.t =
          {
            term = entry_from_param.term;
            index = i;
            data = entry_from_param.data;
          }
        in
        let target_entry = get t i in
        match target_entry with
        | Some existing when existing.term = entry.term && existing.index = entry.index -> ()
        | Some existing when existing.index = entry.index -> set t entry
        | Some existing -> Logger.error t.logger (
            sprintf "Unexpected existing entry was found. existing_entry: %s, new_entry: %s"
              (PersistentLogEntry.show existing)
              (PersistentLogEntry.show entry)
            )
        | None -> add t entry
        ;
        loop (i + 1) rest_of_entries_from_param 
      )
    in
    loop start entries
end

(* Volatile state on all servers *)
module VolatileState = struct
  type t = {
    (* index of highest log entry known to be
     * committed (initialized to 0, increases monotonically) *)
    mutable commit_index : int;
    (* index of highest log entry applied to state
     * machine (initialized to 0, increases monotonically) *)
    mutable last_applied : int;
    (* This is a customized field that isn't shown in the paper *)
    mutable mode : Base.mode;
    (* This is a customized field that isn't shown in the paper *)
    mutable leader_id : int option;
  }
  [@@deriving show]

  let create () = { commit_index = 0; last_applied = 0; mode = FOLLOWER; leader_id = None }

  let log t ~logger = Logger.debug logger ("VolatileState: " ^ show t)

  let update_commit_index t i = t.commit_index <- i

  let update_last_applied t i = t.last_applied <- i

  let commit_index t = t.commit_index

  let detect_higher_commit_index t ~logger ~other =
    if other > t.commit_index
    then (
      Logger.debug logger
        (sprintf "Leader commit(%d) is higher than state.term(%d)" other
           t.commit_index);
      true
    )
    else false

  let last_applied t = t.last_applied

  let apply_logs t ~logger ~f =
    let rec loop () =
      if t.last_applied < t.commit_index
      then (
        let i = t.last_applied + 1 in
        Logger.debug logger
          (sprintf "Applying %dth entry. state.volatile_state.commit_index: %d"
             i (commit_index t));
        f i;
        update_last_applied t i;
        loop ()
      )
    in
    loop ()


  let mode t = t.mode

  let update_mode t ~logger mode =
    t.mode <- mode;
    Logger.info logger (sprintf "Mode is changed to %s" (Base.show_mode mode))

  let leader_id t = t.leader_id

  let update_leader_id t ~logger leader_id =
    match t.leader_id with
    | Some x when x = leader_id -> ()
    | _ -> (
      t.leader_id <- Some leader_id;
      Logger.info logger (sprintf "Leader ID is changed to %d" leader_id)
    )

  let reset_leader_id t ~logger =
    t.leader_id <- None;
    Logger.info logger (sprintf "Leader ID is reset")
end

(* Volatile state on leaders:
 * (Reinitialized after election) *)
module VolatileStateOnLeader = struct
  type peer = {
    (* for each server, index of the next log entry to send
     * to that server (initialized to leader last log index + 1) *)
    mutable next_index : int;
    (* for each server, index of highest log entry known to be replicated on server
     * (initialized to 0, increases monotonically) *)
    mutable match_index : int;
  }
  [@@deriving show]

  type t = peer list [@@deriving show]

  let create ~n ~last_log_index =
    List.init n ~f:(fun _ ->
        { next_index = last_log_index + 1; match_index = 0 })

  let log t ~logger = Logger.debug logger ("VolatileStateOnLeader: " ^ show t)

  let get t i = List.nth_exn t i

  let set_next_index t i x = (List.nth_exn t i).next_index <- x

  let set_match_index t ~logger i x =
    let peer = List.nth_exn t i in
    if peer.match_index > x
    then
      Logger.warn logger
        (sprintf
           "matchIndex should monotonically increase within a term, since servers don't forget entries. But it didn't. match_index: old=%d, new=%d"
           peer.match_index x)
    else peer.match_index <- x

  let show_nth_peer t i = get t i |> show_peer

  let next_index t i = (get t i).next_index

  let match_index t i = (get t i).match_index
end

type common = {
  persistent_state : PersistentState.t;
  persistent_log : PersistentLog.t;
  volatile_state : VolatileState.t;
}

let log t ~logger =
  PersistentState.log t.persistent_state ~logger;
  PersistentLog.log t.persistent_log ~logger;
  VolatileState.log t.volatile_state ~logger


type leader = {
  common : common;
  volatile_state_on_leader : VolatileStateOnLeader.t;
}

let log_leader t ~logger =
  log t.common ~logger;
  VolatileStateOnLeader.log t.volatile_state_on_leader ~logger
