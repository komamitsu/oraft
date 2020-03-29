#!/usr/bin/env bash

set -ex -o pipefail

script_dir=$(dirname $0)
root_dir=$script_dir/../..

pushd $script_dir
rm -f ./oraft-*/oraft.log
rm -rf ./oraft-*/state/
popd

pushd $root_dir
export DOCKER_CONF_DIR=./chaos_test/docker
echo DOCKER_CONF_DIR: $DOCKER_CONF_DIR
echo script_dir: $script_dir
echo current dir: $PWD
docker-compose --project-directory . -f chaos_test/docker/docker-compose.yml build
docker-compose --project-directory . -f chaos_test/docker/docker-compose.yml up
popd

trap "kill $pid_of_docker" EXIT

