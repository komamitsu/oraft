#!/usr/bin/env bash

rm -f ./oraft-*/oraft.log
rm -rf ./oraft-*/state/

docker-compose build
docker-compose up
