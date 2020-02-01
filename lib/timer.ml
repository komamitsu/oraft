open Core
open Lwt

type t = {
  timeout_millis : int;
  logger : Logger.t;
  mutable timeout : Time_ns.t;
  mutable should_stop : bool;
}

let span timeout_millis =
  float_of_int ((timeout_millis / 2) + Random.int timeout_millis)
  |> Time_ns.Span.of_ms


let update t = t.timeout <- Time_ns.add (Time_ns.now ()) (span t.timeout_millis)

let is_timed_out t = Time_ns.( < ) t.timeout (Time_ns.now ())

let start t ~on_stop =
  let rec check_election_timeout () =
    if is_timed_out t || t.should_stop
    then (
      Logger.debug t.logger "Election_timer timed out";
      Lwt.return (on_stop ())
    )
    else Lwt_unix.sleep 0.05 >>= fun () -> check_election_timeout ()
  in
  check_election_timeout ()


let create ~logger ~timeout_millis =
  let t =
    {
      timeout_millis;
      logger;
      timeout = Time_ns.add (Time_ns.now ()) (span timeout_millis);
      should_stop = false;
    }
  in
  t


let stop t = t.should_stop <- true
