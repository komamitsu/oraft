#!/usr/bin/env bash

set -ex -o pipefail

script_dir=$(dirname $0)
root_dir=$script_dir/..
verifier_dir=$root_dir/verifier

# Ideal config...
# wait_after_launch=20
# wait_for_each_op=10
# wait_until_exit=600
# verifier_count=4096
# verifier_wait_ms=250

wait_after_launch=10
wait_for_each_op=5
wait_until_exit=300

pushd $script_dir
./scenario.sh $wait_after_launch $wait_for_each_op $wait_until_exit &
pid_of_scenario=$!
popd

trap "kill $pid_of_scenario" EXIT

sleep $wait_after_launch

# Ideal config...
# $verifier_dir/run.sh -c $verifier_count -w $verifier_wait_ms
$verifier_dir/run.sh

