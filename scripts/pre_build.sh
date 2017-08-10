#!/bin/bash -xe

# Copyright 2017, IBM Corp.
#
# All Rights Reserved
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

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
