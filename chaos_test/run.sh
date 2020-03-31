#!/usr/bin/env bash

set -ex -o pipefail

script_dir=$(dirname $0)
root_dir=$script_dir/..
verifier_dir=$root_dir/verifier
wait_after_launch=30

pushd $script_dir
./docker/build_cluster.sh
./docker/run_cluster.sh &
pid_of_cluster=$!
popd

trap "kill $pid_of_cluster" EXIT

sleep $wait_after_launch

$verifier_dir/run.sh

