#!/usr/bin/env bash

script_dir=$(dirname $0)

pushd $script_dir
rm -f oraft-*/*.log
rm -f oraft-*/state/*
oraft-1/run.sh &
oraft-2/run.sh &
oraft-3/run.sh &
oraft-4/run.sh &
oraft-5/run.sh &
popd
