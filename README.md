# ORaft

Library of [Raft consensus algorithm](https://raft.github.io/raft.pdf) implemented in OCaml 

<img src="https://raw.githubusercontent.com/wiki/komamitsu/oraft/images/oraft-demo.gif" alt="oraft-demo" width="640"/>

## Current Status

### TODO

- Cluster membership changes
- Log compaction

## Requirement

- OCaml 4.14 or later
- opam
- dune

## Build

```
$ opam install --deps-only --with-test .
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
    "node_id": 2,
    "nodes": [
        {"id": 1, "host": "localhost", "port": 7891, "app_port": 8181},
        {"id": 2, "host": "localhost", "port": 7892, "app_port": 8182},
        {"id": 3, "host": "localhost", "port": 7893, "app_port": 8183}
    ],
    "log_file": "oraft.log",
    "log_level": "INFO",
    "state_dir": "state",
    "election_timeout_millis": 200,
    "heartbeat_interval_millis": 50,
    "request_timeout_millis": 100
}

```

`node_id` needs to be modified for each node.

### Write an application using ORaft

The following code is a very simple application that uses ORaft.

```ocaml
let main ~conf_file =
  let oraft =
    Oraft.start ~conf_file ~apply_log:(fun ~node_id ~log_index ~log_data ->
        Printf.printf
          "[node_id:%d, log_index:%d] %s\n"
          node_id log_index log_data;
        flush stdout
    )
  in
  let rec loop () =
    let%lwt s = Lwt_io.read_line Lwt_io.stdin in
    let%lwt result = oraft.post_command s in
    let%lwt _ = Lwt_io.printl (if result then "OK" else "ERR") in
    loop ()
  in
  Lwt.join [ loop (); oraft.process ] |> Lwt_main.run


let () =
  let open Command.Let_syntax in
  Command.basic ~summary:"Simple example application for ORaft"
    [%map_open
      let config =
        flag "config" (required string) ~doc:"CONFIG Config file path"
      in
      fun () -> main ~conf_file:config]
  |> Command_unix.run
```

See `example-simple` project for details.

## Example

This repo contains `example-kv` project that is a simple KVS.

### Run a cluster on multi processes

You can execute the project like this:

```
$ ./example-kv/run_all.sh
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

## Development

### Pre-commit hook

This project uses [pre-commit](https://pre-commit.com/) to automate code format and so on as much as possible. Please [install pre-commit](https://pre-commit.com/#installation) and the git hook script as follows.

```
$ ls -a .pre-commit-config.yaml
.pre-commit-config.yaml
$ pre-commit install
```

The code formatter is automatically executed when commiting files. A commit will fail and be formatted by the formatter when any invalid code format is detected. Try to commit the change again.

