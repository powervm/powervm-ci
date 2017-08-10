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

find -L /opt/stack/logs -type l -delete
sudo systemctl stop devstack@*
for u in `sudo systemctl --no-legend --no-pager list-unit-files 'devstack@*' | awk -F. '{print $1}'`; do
     sudo journalctl -a -o short-precise --unit $u > /opt/stack/logs/${u#*@}.txt
done
mv /opt/stack/logs/stack.sh.log /opt/stack/logs/stack.sh.txt
mv /opt/stack/logs/tempest.log /opt/stack/logs/tempest.txt
sed -i 's/9.\([0-9]\{1,3\}\.\)\{2\}[0-9]\{1,3\}/172.16.0.1/g; s/\([0-9a-zA-Z]*\)\.[0-9a-zA-Z.]*ibm.com/\1.cleared.domain.name/g' /opt/stack/logs/*
apache_logs=$(sudo ls /var/log/apache2/)
for f in $apache_logs; do
   filename=$f
   if [[ "$f" != *gz ]]; then
       filename=$f.txt
   fi
   sudo cp /var/log/apache2/$f /opt/stack/logs/$filename
   sudo chown jenkins:jenkins $filename
done
for f in /opt/stack/logs/*.txt; do
    actual_file=`realpath $f`
    # The -f flag ensures that the file will overwrite any existing files with that name
    gzip -f "$actual_file"
done
