#!/bin/bash

CACHE=/tmp/my_vm_id

function get_my_vm_id {
    if ! [[ -s $CACHE ]]; then
        vm_id=`awk -F= '/^partition_id=/ {print $2}' /proc/ppc64/lparcfg`
        echo -n $vm_id > $CACHE
    fi
    cat $CACHE
}

get_my_vm_id
