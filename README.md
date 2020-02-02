# ORaft

OCaml implementation of [Raft consensus algorithm](https://raft.github.io/raft.pdf)

<img src="https://raw.githubusercontent.com/wiki/komamitsu/oraft/images/oraft-demo.gif" alt="oraft-demo" width="640"/>

## Current Status

### TODO

- Test with [Japsen](https://github.com/jepsen-io/jepsen)
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


```
$ dune runtest
```

## Usage


```ocaml
```

## Example

This project contains `example` directory. You can execute the project like this:

```
$ ./example/run_all.sh
```

5 Raft server processes will start running.


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
