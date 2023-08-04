open Core
open Printf
open Result

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


  let log t ~logger =
    Logger.debug logger ~loc:__LOC__ ("PersistentState : " ^ show t)


  let voted_for t = t.voted_for

  let set_voted_for t ~logger ~voted_for =
    let to_string = function
      | Some x -> "Some " ^ string_of_int x
      | None -> "None"
    in
    Logger.info logger ~loc:__LOC__
      (sprintf "Setting voted_for from %s to %s" (to_string t.voted_for)
         (to_string voted_for)
      );
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
      Logger.info logger ~loc:__LOC__
        (sprintf "Detected the same term: %d, state.term: %d. Stepping down"
           other_term t.current_term
        );
      set_voted_for t ~logger ~voted_for:None;
      true
    )
    else false


  let detect_newer_term t ~logger ~other_term =
    if other_term > t.current_term
    then (
      Logger.info logger ~loc:__LOC__
        (sprintf "Detected newer term: %d, state.term: %d. Stepping down"
           other_term t.current_term
        );
      update_current_term t ~term:other_term;
      t.voted_for <- None;
      save t;
      true
    )
    else false


  let detect_old_leader t ~logger ~other_term =
    if other_term < t.current_term
    then (
      Logger.info logger ~loc:__LOC__
        (sprintf "Detected old leader's term: %d, state.term: %d" other_term
           t.current_term
        );
      true
    )
    else false
end

(* Persistent log state *)
module PersistentLogEntry = struct
  type t = { term : int; index : int; data : string } [@@deriving show, yojson]

  let create ~index ~term ~data = { term; index; data }
  let from_string s = s

  let log t ~logger =
    Logger.debug logger ~loc:__LOC__ ("PersistentLogEntry : " ^ show t)
end

module PersistentLog = struct
  type t = { db : Sqlite3.db; logger : Logger.t }

  let exec_sql_with_result ~db ~logger ~cb ~init ~values ~sql =
    let stmt = Sqlite3.prepare db sql in
    let rc = Sqlite3.bind_names stmt values in
    ignore
      ( match rc with
      | OK -> ()
      | _ ->
          Logger.error logger ~loc:__LOC__
            (Printf.sprintf "SQL prepare-statement failed. sql:[%s]. rc:[%s]"
               sql (Sqlite3.Rc.to_string rc)
            )
      );
    let rc, result = Sqlite3.fold stmt ~f:cb ~init in
    match rc with
    | OK -> Ok result
    | DONE -> Ok result
    | _ ->
        let msg =
          Printf.sprintf "SQL execution failed. sql:[%s]. rc:[%s]" sql
            (Sqlite3.Rc.to_string rc)
        in
        Logger.error logger ~loc:__LOC__ msg;
        Error msg


  let exec_sql_without_result ~db ~logger ~values ~sql =
    let stmt = Sqlite3.prepare db sql in
    let rc = Sqlite3.bind_names stmt values in
    ignore
      ( match rc with
      | OK -> ()
      | DONE -> ()
      | _ ->
          Logger.error logger ~loc:__LOC__
            (Printf.sprintf "SQL prepare-statement failed. sql:[%s]. rc:[%s]"
               sql (Sqlite3.Rc.to_string rc)
            )
      );
    let rc = Sqlite3.step stmt in
    match rc with
    | OK -> Ok ()
    | DONE -> Ok ()
    | _ ->
        let msg =
          Printf.sprintf "SQL execution failed. sql:[%s]. rc:[%s]" sql
            (Sqlite3.Rc.to_string rc)
        in
        Logger.error logger ~loc:__LOC__ msg;
        Error msg


  let setup_db ~path ~logger =
    let db = Sqlite3.db_open path in
    let sql = "select count() from sqlite_schema where name = :table_name" in
    exec_sql_with_result ~db ~logger
      ~cb:(fun count row ->
        let count_result = Array.get row 0 in
        match count_result with
        (* Expecting only a row, but accumulating just in case *)
        | Sqlite3.Data.INT x -> count + Int64.to_int_exn x
        | _ ->
            let count_str = Sqlite3.Data.to_string_debug count_result in
            Logger.error logger ~loc:__LOC__
              (Printf.sprintf "Setting-up database failed. sql:[%s]. count:[%s]"
                 sql count_str
              );
            0
      )
      ~sql
      ~values:[ (":table_name", Sqlite3.Data.TEXT "oraft_log") ]
      ~init:0
    >>= fun count ->
    match count with
    | 0 -> (
        let update_result =
          exec_sql_without_result ~db ~logger
            ~sql:
              "create table if not exists oraft_log (\"index\" int primary key, \"term\" int, \"data\" text)"
            ~values:[]
        in
        match update_result with Ok () -> Ok db | Error _ as err -> err
      )
    | 1 -> Ok db
    | unexpected ->
        let msg =
          Printf.sprintf
            "Setting-up database failed. sql:[%s], error:[Unexpected number of table: %d]"
            sql unexpected
        in
        Logger.error logger ~loc:__LOC__ msg;
        Error msg


  let fetch_from_row ~row ~col_index = Array.get row col_index

  let fetch_int_from_row t ~row ~col_index =
    match fetch_from_row ~row ~col_index with
    | Sqlite3.Data.INT x -> Int64.to_int_exn x
    | _ as wrong_value ->
        let wrong_value_str = Sqlite3.Data.to_string_debug wrong_value in
        Logger.error t.logger ~loc:__LOC__
          (Printf.sprintf "Unexpected type value [%s]" wrong_value_str);
        0


  let fetch_string_from_row t ~row ~col_index =
    match fetch_from_row ~row ~col_index with
    | Sqlite3.Data.TEXT x -> x
    | _ as wrong_value ->
        let wrong_value_str = Sqlite3.Data.to_string_debug wrong_value in
        Logger.error t.logger ~loc:__LOC__
          (Printf.sprintf "Unexpected type value [%s]" wrong_value_str);
        ""


  let log_from_row t ~row =
    (* FIXME: This depends on the order of the SELECT statement *)
    let index = fetch_int_from_row t ~row ~col_index:0 in
    let term = fetch_int_from_row t ~row ~col_index:1 in
    let data = fetch_string_from_row t ~row ~col_index:2 in
    PersistentLogEntry.create ~index ~term ~data


  let load ~state_dir ~logger =
    let path = Filename.concat state_dir "log.db" in
    let result = setup_db ~path ~logger in
    match result with Ok db -> Ok { db; logger } | Error _ as err -> err


  let last_index t =
    exec_sql_with_result ~db:t.db ~logger:t.logger
      ~cb:(fun count row -> count + fetch_int_from_row t ~row ~col_index:0)
      ~sql:"select count(1) from oraft_log" ~values:[] ~init:0


  let fetch t ?(asc = true) n =
    let order = if asc then "asc" else "desc" in
    exec_sql_with_result ~db:t.db ~logger:t.logger
      ~cb:(fun result row ->
        let r = log_from_row t ~row in
        r :: result
      )
      ~sql:
        (sprintf
           "select \"index\", \"term\", \"data\" from oraft_log order by \"index\" %s limit :limit"
           order
        )
      ~values:[ (":limit", Sqlite3.Data.INT (Int64.of_int n)) ]
      ~init:[]


  let show t =
    let entries =
      match fetch t ~asc:false 3 with
      | Ok xs -> String.concat ~sep:", " (List.map xs ~f:PersistentLogEntry.show)
      | Error msg ->
          Printf.sprintf "Failed to fetch last entries. error:[%s]" msg
    in
    let last_index = match last_index t with Ok x -> x | Error _ -> -1 in
    sprintf "{PersistentLog.last_index = %d; last_entries = [%s]}" last_index
      entries


  let log t ~logger =
    Logger.debug logger ~loc:__LOC__ ("PersistentLog: " ^ show t)


  let get t i =
    exec_sql_with_result ~db:t.db ~logger:t.logger
      ~cb:(fun a row -> log_from_row t ~row :: a)
      ~sql:
        "select \"index\", \"term\", \"data\" from oraft_log where \"index\" = :index"
      ~values:[ (":index", Sqlite3.Data.INT (Int64.of_int i)) ]
      ~init:[]
    >>= fun rows ->
    match rows with
    | [] -> Ok None
    | x :: [] -> Ok (Some x)
    | _ ->
        let msg =
          Printf.sprintf
            "Failed to get the record. index:[%d], msg:[Fetched multiple records]"
            i
        in
        Logger.error t.logger ~loc:__LOC__ msg;
        Error msg


  let set_and_truncate_suffix t (entry : PersistentLogEntry.t) =
    exec_sql_without_result ~db:t.db ~logger:t.logger
      ~sql:
        "update oraft_log set \"term\" = :term, \"data\" = :data where \"index\" = :index"
      ~values:
        [
          (":term", Sqlite3.Data.INT (Int64.of_int entry.term));
          (":data", Sqlite3.Data.TEXT entry.data);
          (":index", Sqlite3.Data.INT (Int64.of_int entry.index));
        ]
    >>= fun () ->
    exec_sql_without_result ~db:t.db ~logger:t.logger
      ~sql:"delete from oraft_log where \"index\" > :index"
      ~values:[ (":index", Sqlite3.Data.INT (Int64.of_int entry.index)) ]


  let add t (entry : PersistentLogEntry.t) =
    (* Maybe assertion of the previous entry would be good *)
    exec_sql_without_result ~db:t.db ~logger:t.logger
      ~sql:
        "insert into oraft_log (\"index\", \"term\", \"data\") values (:index, :term, :data)"
      ~values:
        [
          (":term", Sqlite3.Data.INT (Int64.of_int entry.term));
          (":data", Sqlite3.Data.TEXT entry.data);
          (":index", Sqlite3.Data.INT (Int64.of_int entry.index));
        ]


  let last_log t =
    last_index t >>= fun last_index ->
    match last_index with
    | last_index when last_index > 0 -> (
        match get t last_index with
        | Ok last_log -> Ok last_log
        | Error msg ->
            let msg =
              Printf.sprintf
                "Failed to get last log. last_index:[%d], error:[%s]" last_index
                msg
            in
            Logger.error t.logger ~loc:__LOC__ msg;
            Error msg
      )
    | _ -> Ok None


  let append t ~entries =
    let rec loop (entries : PersistentLogEntry.t list) =
      if List.length entries > 0
      then (
        let entry = List.hd_exn entries in
        let rest_of_entries_from_param = List.tl_exn entries in
        let result =
          get t entry.index >>= fun corresponding_entry ->
          match corresponding_entry with
          | Some existing when entry.index <> existing.index ->
              let msg =
                sprintf
                  "Failed to append entries. Unexpected existing entry was found. existing_entry: %s, new_entry: %s"
                  (PersistentLogEntry.show existing)
                  (PersistentLogEntry.show entry)
              in
              Logger.error t.logger ~loc:__LOC__ msg;
              Error msg
          | Some existing when entry.term <> existing.term -> (
              match set_and_truncate_suffix t entry with
              | Ok () -> Ok ()
              | Error msg ->
                  let msg =
                    sprintf "Failed to append entries. error:[%s]" msg
                  in
                  Error msg
            )
          | Some _ -> Ok ()
          | None -> (
              match add t entry with
              | Ok () -> Ok ()
              | Error msg ->
                  let msg =
                    sprintf "Failed to append entries. error:[%s]" msg
                  in
                  Error msg
            )
        in
        match result with
        | Ok _ -> loop rest_of_entries_from_param
        | Error msg -> Error msg
      )
      else Ok ()
    in
    loop entries
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

  let create () =
    { commit_index = 0; last_applied = 0; mode = FOLLOWER; leader_id = None }


  let log t ~logger =
    Logger.debug logger ~loc:__LOC__ ("VolatileState: " ^ show t)


  let update_commit_index t i = t.commit_index <- i
  let update_last_applied t i = t.last_applied <- i
  let commit_index t = t.commit_index

  let detect_higher_commit_index t ~logger ~other =
    if other > t.commit_index
    then (
      Logger.debug logger ~loc:__LOC__
        (sprintf "Leader commit(%d) is higher than state.term(%d)" other
           t.commit_index
        );
      true
    )
    else false


  let last_applied t = t.last_applied

  let apply_logs t ~logger ~f =
    let rec loop () =
      if t.last_applied < t.commit_index
      then (
        let i = t.last_applied + 1 in
        Logger.debug logger ~loc:__LOC__
          (sprintf "Applying %dth entry. state.volatile_state.commit_index: %d"
             i (commit_index t)
          );
        f i;
        update_last_applied t i;
        loop ()
      )
    in
    loop ()


  let mode t = t.mode

  let update_mode t ~logger mode =
    t.mode <- mode;
    Logger.info logger ~loc:__LOC__
      (sprintf "Mode is changed to %s" (Base.show_mode mode))


  let leader_id t = t.leader_id

  let update_leader_id t ~logger leader_id =
    match t.leader_id with
    | Some x when x = leader_id -> ()
    | _ ->
        t.leader_id <- Some leader_id;
        Logger.info logger ~loc:__LOC__
          (sprintf "Leader ID is changed to %d" leader_id)


  let reset_leader_id t ~logger =
    t.leader_id <- None;
    Logger.info logger ~loc:__LOC__ (sprintf "Leader ID is reset")
end

(* Volatile state on leaders:
 * (Reinitialized after election) *)
module VolatileStateOnLeader = struct
  type peer = {
    (* For each server, index of the next log entry to send
     * to that server (initialized to leader last log index + 1) *)
    mutable next_index : int;
    (* For each server, index of highest log entry known to be replicated on server
     * (initialized to 0, increases monotonically) *)
    mutable match_index : int;
  }
  [@@deriving show]

  type t = peer list [@@deriving show]

  let create ~n ~last_log_index =
    List.init n ~f:(fun _ ->
        { next_index = last_log_index + 1; match_index = 0 }
    )


  let log t ~logger =
    Logger.debug logger ~loc:__LOC__ ("VolatileStateOnLeader: " ^ show t)


  let get t i = List.nth_exn t i
  let set_next_index t i x = (List.nth_exn t i).next_index <- x

  let set_match_index t ~logger i x =
    let peer = List.nth_exn t i in
    if peer.match_index > x
    then
      Logger.warn logger ~loc:__LOC__
        (sprintf
           "matchIndex should monotonically increase within a term, since servers don't forget entries. But it didn't. match_index: old=%d, new=%d"
           peer.match_index x
        )
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
