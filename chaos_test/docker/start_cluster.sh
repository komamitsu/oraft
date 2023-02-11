#!/usr/bin/env bash

set -ex -o pipefail

script_dir=$(dirname $0)
root_dir=$script_dir/../..

pushd $script_dir
sudo rm -f ./oraft-*/oraft.log
sudo rm -rf ./oraft-*/state/
popd

pushd $root_dir
export DOCKER_CONF_DIR=./chaos_test/docker
docker-compose --project-directory . -f chaos_test/docker/docker-compose.yml up -d
docker-compose --project-directory . -f chaos_test/docker/docker-compose.yml logs -f -t --no-color \
    | awk -F' ' '{ts = $3; $3 = ""; print ts,$0}' \
    | tee chaos_test_docker.log &
popd

