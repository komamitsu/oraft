#!/usr/bin/env bash

script_dir=$(dirname $0)

pushd $script_dir
rm -f *.log
rm -f state/*
dune exec --root ../.. example-simple/oraft_simple.exe -- -config conf.json
popd

