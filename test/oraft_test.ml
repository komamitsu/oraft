open Core
open OUnit2
open Oraft__State

let test_persistent_log_append _ =
  let with_tmpdir f =
    let rand = Printf.sprintf "%010d" @@ Random.int 10000000 in
    let tmpdir = Filename.concat Filename.temp_dir_name rand in
    Unix.mkdir_p tmpdir;
    try f tmpdir with _ -> FileUtil.rm ~recurse:true [ tmpdir ]
  in
  with_tmpdir (fun tmpdir ->
      (* Initial *)
      let log = PersistentLog.load tmpdir in
      assert_equal None (PersistentLog.get log 1);
      assert_equal 0 (PersistentLog.last_index log);
      assert_equal 0 (PersistentLog.last_log log).term;
      assert_equal 0 (PersistentLog.last_log log).index;
      (* Add a log *)
      PersistentLog.append log 1 (PersistentLog.last_index log + 1) [ "First" ];
      let l = PersistentLog.get_exn log 1 in
      assert_equal 1 l.term;
      assert_equal 1 l.index;
      assert_equal "First" l.data;
      assert_equal 1 (PersistentLog.last_index log);
      assert_equal 1 (PersistentLog.last_log log).term;
      assert_equal 1 (PersistentLog.last_log log).index;
      (* Add another log *)
      PersistentLog.append log 2 (PersistentLog.last_index log + 1) [ "Second" ];
      let l = PersistentLog.get_exn log 2 in
      assert_equal 2 l.term;
      assert_equal 2 l.index;
      assert_equal "Second" l.data;
      assert_equal 2 (PersistentLog.last_index log);
      assert_equal 2 (PersistentLog.last_log log).term;
      assert_equal 2 (PersistentLog.last_log log).index;
      (* Add more 2 logs overriding the last log,
       * but it's the same term and the old entry should remain *)
      PersistentLog.append log 2
        (PersistentLog.last_index log + 0)
        [ "Second2"; "Third" ];
      let l = PersistentLog.get_exn log 2 in
      assert_equal 2 l.term;
      assert_equal 2 l.index;
      assert_equal "Second" l.data;
      let l = PersistentLog.get_exn log 3 in
      assert_equal 2 l.term;
      assert_equal 3 l.index;
      assert_equal "Third" l.data;
      assert_equal 3 (PersistentLog.last_index log);
      assert_equal 2 (PersistentLog.last_log log).term;
      assert_equal 3 (PersistentLog.last_log log).index;
      (* Add more 2 logs overriding the last log with different term *)
      PersistentLog.append log 3
        (PersistentLog.last_index log + 0)
        [ "Third2"; "Four" ];
      let assert_all log =
        let l = PersistentLog.get_exn log 2 in
        assert_equal 2 l.term;
        assert_equal 2 l.index;
        assert_equal "Second" l.data;
        let l = PersistentLog.get_exn log 3 in
        assert_equal 3 l.term;
        assert_equal 3 l.index;
        assert_equal "Third2" l.data;
        let l = PersistentLog.get_exn log 4 in
        assert_equal 3 l.term;
        assert_equal 4 l.index;
        assert_equal "Four" l.data;
        assert_equal 4 (PersistentLog.last_index log);
        assert_equal 3 (PersistentLog.last_log log).term;
        assert_equal 4 (PersistentLog.last_log log).index
      in
      assert_all log;
      (* Load the state *)
      let log = PersistentLog.load tmpdir in
      assert_all log)

let suite =
  "ORaft tests"
  >::: [ "test_persistent_log_append" >:: test_persistent_log_append ]

let () =
  Printexc.record_backtrace true;
  ignore (run_test_tt_main suite)
