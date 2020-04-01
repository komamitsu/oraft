# ORaft

Library of [Raft consensus algorithm](https://raft.github.io/raft.pdf) implemented in OCaml 

<img src="https://raw.githubusercontent.com/wiki/komamitsu/oraft/images/oraft-demo.gif" alt="oraft-demo" width="640"/>

## Current Status

### TODO

- Cluster membership changes
- Log compaction

## Requirement

- opam
- dune

## Build

```
$ opam install --deps-only .
$ dune build
```

## Install

```
$ opam install .
```

## Test


### Unit test

```
$ dune runtest
```

### Smoke test

This repository has an example Raft application that is a simple KVS as described below. The following command runs 5 KVS servers and a verification tool that sequentially restarts at most 2 servers.

```
$ smoke_test/run.sh
```

### Chaos test

This repository has an example Raft application that is a simple KVS as described below. The following command runs 5 KVS servers, a verification tool and [chaos testing tool](https://github.com/alexei-led/pumba) in docker containers. The 5 KVS servers will randomly experience pause and network delay.

```
$ chaos_test/run.sh
```

## Usage

### Create a config file for each Raft application

```json
{
    "node_id": 4,
    "nodes": [
        {"id": 1, "host": "localhost", "port": 7891},
        {"id": 2, "host": "localhost", "port": 7892},
        {"id": 3, "host": "localhost", "port": 7893},
        {"id": 4, "host": "localhost", "port": 7894},
        {"id": 5, "host": "localhost", "port": 7895}
    ],
    "log_file": "oraft.log",
    "log_level": "INFO",
    "state_dir": "state",
    "election_timeout_millis": 300,
    "heartbeat_interval_millis": 50
}
```

`node_id` needs to be modified for each node.

### Write an application using ORaft

The following code is a very simple application that uses ORaft.

```ocaml
open Lwt

let main =
  let oraft =
    Oraft.start ~conf_file:"/path/to/oraft-config.json" ~apply_log:(fun i s ->
      Printf.printf
        "Received %d th command. Maybe you'd better take care of '%s' instead of just printing\n" i s;
      flush stdout
    )
  in
  let rec loop () = Lwt_io.read_line Lwt_io.stdin
    >>= fun s -> oraft.post_command s
    >>= fun result -> Lwt_io.printl (if result then "OK" else "ERR")
    >>= fun () -> loop ()
  in
  Lwt.join [ loop (); oraft.process ] |> Lwt_main.run
```

## Example

This repo contains `example` project that is a simple KVS.

### Run a cluster on multi processes

You can execute the project like this:

```
$ ./example/run_all.sh
```

5 Raft application processes will start.


And then, you can send a request using `curl` command or something

```
$ curl -X POST --data-binary 'SET a hello' http://localhost:8181/command
$ curl -X POST --data-binary 'GET a' http://localhost:8182/command
hello
$ curl -X POST --data-binary 'SET b 42' http://localhost:8183/command
$ curl -X POST --data-binary 'GET b' http://localhost:8184/command
42
$ curl -X POST --data-binary 'INCR b' http://localhost:8185/command
$ curl -X POST --data-binary 'GET b' http://localhost:8181/command
43
```



