#!/usr/bin/env bash

set -ex -o pipefail

script_dir=$(dirname $0)

pushd $script_dir
bundle install
bundle exec verifier
popd

