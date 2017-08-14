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

zuul_branch=$1
log_path=/opt/stack/logs
find -L $log_path -type l -delete
sudo systemctl stop devstack@*
if [ "$zuul_branch" == "stable/newton" ] || [ "$zuul_branch" == "stable/ocata" ]; then
    for f in $log_path/*.log; do
        mv -- "$f" "${f%.log}.txt"
    done
else
    sudo systemctl stop devstack@*
    for u in `sudo systemctl --no-legend --no-pager list-unit-files 'devstack@*' | awk -F. '{print $1}'`; do
        sudo journalctl -a -o short-precise --unit $u > $log_path/${u#*@}.txt
    done
    mv $log_path/stack.sh.log $log_path/stack.sh.txt
    mv $log_path/tempest.log $log_path/tempest.txt
fi
apache_logs=$(sudo ls /var/log/apache2/)
for f in $apache_logs; do
   filename=$f
   if [[ "$f" != *.gz ]]; then
       filename=$f.txt
   fi
   sudo cp /var/log/apache2/$f $log_path/$filename
   sudo chown jenkins:jenkins $log_path/$filename
done
sed -i 's/9.\([0-9]\{1,3\}\.\)\{2\}[0-9]\{1,3\}/172.16.0.1/g; s/\([0-9a-zA-Z]*\)\.[0-9a-zA-Z.]*ibm.com/\1.cleared.domain.name/g' $log_path/*
for f in $log_path/*.txt; do
    actual_file=`realpath $f`
    # The -f flag ensures that the file will overwrite any existing files with that name
    gzip -f "$actual_file"
done
