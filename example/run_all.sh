#!/usr/bin/env bash

rm -f oraft-*/*.log
rm -f oraft-*/state/*

pushd ..
example/oraft-1/run.sh &
example/oraft-2/run.sh &
example/oraft-3/run.sh &
example/oraft-4/run.sh &
example/oraft-5/run.sh &
popd

