#!/usr/bin/env bash

set -ex -o pipefail

root_dir=$(dirname $0)/..
example_dir=$root_dir/example
wait_after_launch=$1
wait_for_each_op=$2
wait_until_exit=$3

# Clear state and log files in `example`
pushd $example_dir
rm -rf oraft-*/oraft.log
rm -rf oraft-*/state
popd

function run_1st_server() {
    $example_dir/oraft-1/run.sh &
    pid_of_1st_server=$!
}

function run_2nd_server() {
    $example_dir/oraft-2/run.sh &
    pid_of_2nd_server=$!
}

function run_3rd_server() {
    $example_dir/oraft-3/run.sh &
    pid_of_3rd_server=$!
}

function run_4th_server() {
    $example_dir/oraft-4/run.sh &
    pid_of_4th_server=$!
}

function run_5th_server() {
    $example_dir/oraft-5/run.sh &
    pid_of_5th_server=$!
}

function kill_1st_server() {
    kill_server $pid_of_1st_server
}

function kill_2nd_server() {
    kill_server $pid_of_2nd_server
}

function kill_3rd_server() {
    kill_server $pid_of_3rd_server
}

function kill_4th_server() {
    kill_server $pid_of_4th_server
}

function kill_5th_server() {
    kill_server $pid_of_5th_server
}

function kill_server() {
    pid=$1
    target_pid=$(ps -Ao ppid,pid,command | awk -v pid=$pid '($1 == pid && $3 == "example/oraft_example.exe") { print $2 }')
    if [[ -n $target_pid ]]; then
        kill $target_pid
    fi
}

function kill_all_servers() {
    if [[ -v pid_of_1st_server ]]; then
        kill_server $pid_of_1st_server
    fi

    if [[ -v pid_of_2nd_server ]]; then
        kill_server $pid_of_2nd_server
    fi

    if [[ -v pid_of_3rd_server ]]; then
        kill_server $pid_of_3rd_server
    fi

    if [[ -v pid_of_4th_server ]]; then
        kill_server $pid_of_4th_server
    fi

    if [[ -v pid_of_5th_server ]]; then
        kill_server $pid_of_5th_server
    fi
}

trap kill_all_servers EXIT

run_1st_server
run_2nd_server
run_3rd_server
run_4th_server
run_5th_server

sleep $wait_after_launch

kill_1st_server
sleep $wait_for_each_op

kill_2nd_server
sleep $wait_for_each_op

run_1st_server
sleep $wait_for_each_op
kill_3rd_server
sleep $wait_for_each_op

run_2nd_server
sleep $wait_for_each_op
kill_4th_server
sleep $wait_for_each_op

run_3rd_server
sleep $wait_for_each_op
kill_5th_server
sleep $wait_for_each_op

run_4th_server
sleep $wait_for_each_op

run_5th_server
sleep $wait_for_each_op

# Wait until receiving kill signal from run.sh
sleep $wait_until_exit

