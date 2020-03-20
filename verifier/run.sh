#!/usr/bin/env bash

script_dir=$(dirname $0)

pushd $script_dir
bundle exec verifier
popd

