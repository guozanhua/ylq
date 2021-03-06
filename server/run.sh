#!/bin/bash

FLAG=$1
BFLAG=$FLAG"_bs"
CFLAG=$FLAG"_cs"
GFLAG=$FLAG"_gs"
if [ -z $FLAG ] ; then
    BFLAG=undefine_bs
    CFLAG=undefine_cs
    GFLAG=undefine_gs
fi
./shell/bs_run.sh $BFLAG
sleep 6
./shell/cs_run.sh $CFLAG
sleep 6
./shell/gs_run.sh $GFLAG
sleep 12
./shell/open_gate.sh 2 $GFLAG