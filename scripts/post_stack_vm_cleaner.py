# Copyright 2014, 2017 IBM Corp.
#
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import subprocess

from pypowervm import adapter
from pypowervm import const
from pypowervm.tasks import power
from pypowervm.tasks import storage as tsk_stor
from pypowervm import util as pvm_util
from pypowervm.utils import transaction as tx
from pypowervm.wrappers import logical_partition as pvm_lpar
from pypowervm.wrappers import managed_system as pvm_ms
from pypowervm.wrappers import virtual_io_server as pvm_vios

# This script runs after a devstack compute run.  Its purpose is to clean up
# any VMs that were left around from a tempest test.  Tempest may fail half
# way through and leave a bunch of VMs laying around.
#
# For KVM, this isn't a big deal.  Deleting the parent node kills all the
# nested children VMs.  But in PowerVM, each of those VMs are 'peers'.  So they
# need to be manually removed.
#
# This is expected to be run as a post-tempest step from the Jenkins Job
# Builder (JJB), for both success and failure runs.


def find_and_stop_target_vms(adpt, host_uuid):
    """Find and stop all vms created for tempest testing."""
    lpar_id = pvm_util.my_partition_id()

    # Get each LPAR and see if it was created for this process
    lpar_wraps = pvm_lpar.LPAR.get(adpt)
    actual_lpar_wraps = []
    for lpar_w in lpar_wraps:
        # All instances created by tempest will start with this prefix as
        # specified by the instance_name_template set in prep_devstack.sh
        if not lpar_w.name.startswith('pvm%s-tempest' % lpar_id):
            continue
            power.power_off_progressive(lpar_w, host_uuid,
                                        force_immediate=True)
        actual_lpar_wraps.append(lpar_w)

    return actual_lpar_wraps


def scrub_storage(adpt, lpar_wraps):
    ftsk = tx.FeedTask(pvm_vios.VIOS.getter(adpt, xag=[const.XAG.VIO_SMAP]))
    tsk_stor.add_lpar_storage_scrub_tasks(
        [lwrap.id for lwrap in lpar_wraps], ftsk, lpars_exist=True)
    ftsk.execute()


def delete_lpars(adpt, lpar_wraps):
    for lpar_wrap in lpar_wraps:
        try:
            lpar_wrap.delete()
        except Exception:
            print "Non blocking VM delete error."


def main():
    try:
        adpt = adapter.Adapter()
        ms = pvm_ms.System.get(adpt)[0]

        # Find and stop the tempest VMs that are paired to this system.
        lpar_wraps = find_and_stop_target_vms(adpt, ms.uuid)

	# Remove stale vSCSI mappings and backing storage.
	scrub_storage = scrub_storage(adpt, lpar_wraps)

        # And end with a delete of the VMs
        delete_lpars(adpt, lpar_wraps)
    except Exception as e:
        print str(e)
        print "Error during clean up.  Non-blocking"


# Run the cleaner
main()
