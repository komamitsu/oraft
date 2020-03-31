#!/usr/bin/env bash

set -ex -o pipefail

script_dir=$(dirname $0)
root_dir=$script_dir/../..

pushd $root_dir
export DOCKER_CONF_DIR=./chaos_test/docker
docker-compose --project-directory . -f chaos_test/docker/docker-compose.yml build
popd

