#!/bin/bash

function devstack_checkout {
    if [[ ! -e /opt/stack/devstack ]]; then
        git clone git://git.openstack.org/openstack-dev/devstack /opt/stack/devstack
    else
        cd /opt/stack/devstack
        git remote set-url origin git://git.openstack.org/openstack-dev/devstack
        git remote update
        git reset --hard
        if ! git clean -x -f ; then
            sleep 1
            git clean -x -f
        fi
        git checkout master
        git reset --hard remotes/origin/master
        if ! git clean -x -f ; then
            sleep 1
            git clean -x -f
        fi
        cd -
    fi
}

function host_info {
    echo "NEO HOST"
    sudo /usr/sbin/rsct/bin/getRTAS | sed -n 's/.*HscHostName=\(neo[^;]*\);.*/\1/p'
}

host_info
devstack_checkout
