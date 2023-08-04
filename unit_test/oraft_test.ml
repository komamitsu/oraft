open Core
open OUnit2
open Oraft__State

let assert_result expected actual_result =
  match actual_result with
  | Ok actual -> assert_equal expected actual
  | Error msg -> assert_failure msg


let expect_ok f =
  match f with Ok result -> result | Error msg -> assert_failure msg


let expect_some f = match f with Some x -> x | None -> assert_failure "None"

let test_persistent_log_append _ =
  (* FIXME: output_path *)
  let logger = Oraft__Logger.create ~node_id:42 ~level:"INFO" () in
  let with_tmpdir f =
    let rand = Printf.sprintf "%010d" @@ Random.int 10000000 in
    let tmpdir = Filename.concat Filename.temp_dir_name rand in
    Core_unix.mkdir_p tmpdir;
    Fun.protect
      (fun () -> f tmpdir)
      ~finally:(fun () -> FileUtil.rm ~recurse:true [ tmpdir ])
  in
  with_tmpdir (fun tmpdir ->
      (* Initial *)
      match PersistentLog.load ~state_dir:tmpdir ~logger with
      | Ok log ->
          assert_result None (PersistentLog.get log 1);
          assert_result 0 (PersistentLog.last_index log);
          assert_result None (PersistentLog.last_log log);
          (* Add a log *)
          assert_result ()
            (PersistentLog.append log
               ~entries:[ { term = 1; index = 1; data = "First" } ]
            );
          (* Current status:
             - index:1, term:1, data:First
          *)
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 1 in
          assert_equal 1 l.term;
          assert_equal 1 l.index;
          assert_equal "First" l.data;
          assert_result 1 (PersistentLog.last_index log);
          let last_log =
            expect_some @@ expect_ok @@ PersistentLog.last_log log
          in
          assert_equal 1 last_log.term;
          assert_equal 1 last_log.index;

          (* Add another log *)
          assert_result ()
            (PersistentLog.append log
               ~entries:[ { term = 2; index = 2; data = "Second" } ]
            );
          (* Current status:
             - index:1, term:1, data:First
             - index:2, term:2, data:Second
          *)
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 2 in
          assert_equal 2 l.term;
          assert_equal 2 l.index;
          assert_equal "Second" l.data;
          assert_result 2 (PersistentLog.last_index log);
          let last_log =
            expect_some @@ expect_ok @@ PersistentLog.last_log log
          in
          assert_equal 2 last_log.term;
          assert_equal 2 last_log.index;

          (* Add more 2 logs overriding the last log,
           * but it's the same term and the old entry should remain *)
          assert_result ()
            (PersistentLog.append log
               ~entries:
                 [
                   { term = 2; index = 2; data = "Second" };
                   { term = 2; index = 3; data = "Third" };
                 ]
            );
          (* Current status:
             - index:1, term:1, data:First
             - index:2, term:2, data:Second
             - index:3, term:2, data:Third
          *)
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 2 in
          assert_equal 2 l.term;
          assert_equal 2 l.index;
          assert_equal "Second" l.data;
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 3 in
          assert_equal 2 l.term;
          assert_equal 3 l.index;
          assert_equal "Third" l.data;
          assert_result 3 (PersistentLog.last_index log);
          let last_log =
            expect_some @@ expect_ok @@ PersistentLog.last_log log
          in
          assert_equal 2 last_log.term;
          assert_equal 3 last_log.index;

          (* Add more 3 logs overriding the last log with different term *)
          assert_result ()
            (PersistentLog.append log
               ~entries:
                 [
                   { term = 3; index = 3; data = "Third2" };
                   { term = 4; index = 4; data = "Fourth" };
                   { term = 5; index = 5; data = "Fifth" };
                 ]
            );
          (* Current status:
             - index:1, term:1, data:First
             - index:2, term:2, data:Second
             - index:3, term:3, data:Third2
             - index:4, term:4, data:Fourth
             - index:5, term:5, data:Fifth
          *)
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 3 in
          assert_equal 3 l.term;
          assert_equal 3 l.index;
          assert_equal "Third2" l.data;
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 4 in
          assert_equal 4 l.term;
          assert_equal 4 l.index;
          assert_equal "Fourth" l.data;
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 5 in
          assert_equal 5 l.term;
          assert_equal 5 l.index;
          assert_equal "Fifth" l.data;
          assert_result 5 (PersistentLog.last_index log);
          let last_log =
            expect_some @@ expect_ok @@ PersistentLog.last_log log
          in
          assert_equal 5 last_log.term;
          assert_equal 5 last_log.index;

          (* Add a log overriding the fourth log with different term *)
          assert_result ()
            (PersistentLog.append log
               ~entries:[ { term = 5; index = 4; data = "Fourth2" } ]
            );
          (* Current status:
              - index:1, term:1, data:First
              - index:2, term:2, data:Second
              - index:3, term:3, data:Third2
              - index:4, term:5, data:Fourth2

             index:5 is truncated just in case. This behavior is not defined in the papar, though
          *)
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 3 in
          assert_equal 3 l.term;
          assert_equal 3 l.index;
          assert_equal "Third2" l.data;
          let l = expect_some @@ expect_ok @@ PersistentLog.get log 4 in
          assert_equal 5 l.term;
          assert_equal 4 l.index;
          assert_equal "Fourth2" l.data;
          assert_result None (PersistentLog.get log 5);
          assert_result 4 (PersistentLog.last_index log);
          let last_log =
            expect_some @@ expect_ok @@ PersistentLog.last_log log
          in
          assert_equal 5 last_log.term;
          assert_equal 4 last_log.index;

          let assert_all log =
            let l = expect_some @@ expect_ok @@ PersistentLog.get log 2 in
            assert_equal 2 l.term;
            assert_equal 2 l.index;
            assert_equal "Second" l.data;
            let l = expect_some @@ expect_ok @@ PersistentLog.get log 3 in
            assert_equal 3 l.term;
            assert_equal 3 l.index;
            assert_equal "Third2" l.data;
            let l = expect_some @@ expect_ok @@ PersistentLog.get log 4 in
            assert_equal 5 l.term;
            assert_equal 4 l.index;
            assert_equal "Fourth2" l.data;
            assert_result 4 (PersistentLog.last_index log);
            let last_log =
              expect_some @@ expect_ok @@ PersistentLog.last_log log
            in
            assert_equal 5 last_log.term;
            assert_equal 4 last_log.index
          in
          assert_all log
          (* Load the state *)
          (* FIXME *)
          (* let log = PersistentLog.load ~state_dir:tmpdir ~logger in *)
          (* assert_all log *)
      | Error msg -> assert_failure msg
  )


let suite =
  "ORaft tests"
  >::: [ "test_persistent_log_append" >:: test_persistent_log_append ]


let () =
  Printexc.record_backtrace true;
  run_test_tt_main suite
