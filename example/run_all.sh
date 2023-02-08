#!/usr/bin/env bash

script_dir=$(dirname $0)

pushd $script_dir
rm -f oraft-*/*.log
rm -f oraft-*/state/*
oraft-1/run.sh &
# These sleeps are to avoid conflicts on _build/.lock
sleep 1
oraft-2/run.sh &
sleep 1
oraft-3/run.sh &
sleep 1
oraft-4/run.sh &
sleep 1
oraft-5/run.sh &
sleep 1
popd
