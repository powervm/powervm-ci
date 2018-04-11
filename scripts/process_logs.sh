#!/bin/bash -x

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

CONTROL=${CONTROL:-true}

zuul_branch=$1
logserver_user=$2
logserver_ip=$3

# Base log path for logserver
zuul_log_path=$4
if $CONTROL; then
    logserver_path=/srv/static/logs/$zuul_log_path/control
else
    logserver_path=/srv/static/logs/$zuul_log_path/compute
fi

# Path to logs on all-in-one test vms
stack_log_path=/opt/stack/logs

# Build URL used to get jenkins console log
build_url=$5

find -L $stack_log_path -type l -delete

# Branches after ocata use journald for logging. These need to be output to files
# to be copied to the logserver.
if [ "$zuul_branch" != "stable/ocata" ]; then
    sudo systemctl stop devstack@*
    for u in `sudo systemctl --no-legend --no-pager list-unit-files 'devstack@*' | awk -F. '{print $1}'`; do
        sudo journalctl -a -o short-precise --unit $u > $stack_log_path/${u#*@}.txt
    done
fi

# Rename any additional log files with .txt extension for in browser viewing.
for f in $stack_log_path/*.log; do
    mv -- "$f" "${f%.log}.txt"
done

# Copy apache logs to stack_log_path so they get picked up by scp to logserver.
apache_logs=$(sudo ls /var/log/apache2/)
for f in $apache_logs; do
   filename=$f
   if [[ "$f" != *.gz ]]; then
       filename=$f.txt
   fi
   sudo cp /var/log/apache2/$f $stack_log_path/$filename
   sudo chown jenkins:jenkins $stack_log_path/$filename
done

# Output jenkins console log to file
wget $build_url/consoleText -O $stack_log_path/console.txt

# Scrub IPs and domain names
sed -i 's/9.\([0-9]\{1,3\}\.\)\{2\}[0-9]\{1,3\}/172.16.0.1/g; s/\([0-9a-zA-Z]*\)\.[0-9a-zA-Z.]*ibm.com/\1.cleared.domain.name/g' $stack_log_path/*

# Zip all logs
for f in $stack_log_path/*.txt; do
    actual_file=`realpath $f`
    # The -f flag ensures that the file will overwrite any existing files with that name
    gzip -f "$actual_file"
done

# Copy logs to logserver
eval `ssh-agent -s`
ssh-add /opt/nodepool-scripts/osci_rsa
ssh-keyscan $logserver_ip >> ~/.ssh/known_hosts
ssh $logserver_user@$logserver_ip "mkdir -p $logserver_path/logs"
scp $stack_log_path/*.gz $logserver_user@$logserver_ip:$logserver_path/logs/

if $CONTROL; then
    scp $stack_log_path/*powervm_os_ci* $logserver_user@$logserver_ip:$logserver_path
fi
