#!/usr/bin/env bash

set -ex

script_dir=$(dirname $0)

pushd $script_dir
rm -f ./oraft-*/oraft.log
rm -rf ./oraft-*/state/
popd

pushd $script_dir/../..
export DOCKER_CONF_DIR=$script_dir
docker-compose --project-directory . -f $script_dir/docker-compose.yml build
docker-compose --project-directory . -f $script_dir/docker-compose.yml up
popd

