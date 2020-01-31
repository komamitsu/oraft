#!/usr/bin/env bash

script_dir=$(dirname $0)

pushd $script_dir
dune exec --root ../.. example/oraft_example.exe 8185 conf.json
popd

