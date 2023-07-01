#!/usr/bin/env bash

script_dir=$(dirname $0)

pushd $script_dir
dune exec --root ../.. example-kv/oraft_kv.exe 8182 conf.json
popd

