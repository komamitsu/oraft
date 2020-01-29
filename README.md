# ORaft

OCaml implementation of [Raft consensus algorithm](https://raft.github.io/raft.pdf)


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
$ curl -X POST --data-binary 'SET c hello' http://localhost:8185/command
$ curl -X POST --data-binary 'GET c' http://localhost:8183/command
hello
```
