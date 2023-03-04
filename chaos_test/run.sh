#!/usr/bin/env bash

set -ex -o pipefail

script_dir=$(dirname $0)
root_dir=$script_dir/..
verifier_dir=$root_dir/verifier

pushd $root_dir
rm -f chaos_test*.log
popd

pushd $script_dir
./docker/build_cluster.sh
./docker/start_cluster.sh
popd

teardown () {
    # Stop cluster
    pushd $script_dir
    ./docker/stop_cluster.sh
    popd

    # Create a sorted log
    pushd $root_dir
    cat chaos_test_docker.log chaos_test_verifier.log chaos_test/docker/oraft-*/oraft.log | sort | tool/log-indent > chaos_test_sorted.log
    popd
}
trap teardown EXIT

$verifier_dir/run.sh -m set -c 2048 -k 2048 | tee chaos_test_verifier.log

