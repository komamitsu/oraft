#!/usr/bin/env bash

set -ex -o pipefail

script_dir=$(dirname $0)
root_dir=$script_dir/..
verifier_dir=$root_dir/verifier

pushd $script_dir
./docker/build_cluster.sh
./docker/start_cluster.sh
popd

stop_cluster () {
    pushd $script_dir
    ./docker/stop_cluster.sh
    popd
}
trap stop_cluster EXIT

$verifier_dir/run.sh
