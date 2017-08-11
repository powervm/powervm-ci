# Copyright 2014, 2016 IBM Corp.
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
from pypowervm.tasks import power
from pypowervm import util as pvm_util
from pypowervm.wrappers import base_partition as pvm_bp
from pypowervm.wrappers import logical_partition as pvm_lpar
from pypowervm.wrappers import managed_system as pvm_ms
from pypowervm.wrappers import network as pvm_net
from pypowervm.wrappers import storage as pvm_stor
from pypowervm.wrappers import virtual_io_server as pvm_vios

# This script runs post a devstack compute run.  Its purpose is to clean up
# any VMs that were left around from a tempest test.  Tempest may fail half
# way through and leave a bunch of VMs laying around.
#
# For KVM, this isn't a big deal.  Deleting the parent node kills all the
# nested children VMs.  But in PowerVM, each of those VMs are 'peers'.  So they
# need to be manually removed.
#
# This is expected to be run as a post-tempest step from the Jenkins Job
# Builder (JJB), for both success and failure runs.


def find_all_target_vms(adpt, host_uuid):
    """Finds the peer VMs."""
    lpar_id = pvm_util.my_partition_id()

    # Get each LPAR and see if it was created for this process
    lpar_wraps = pvm_lpar.LPAR.get(adpt)
    actual_lpar_wraps = []
    for lpar_w in lpar_wraps:
        if not lpar_w.name.startswith('pvm%s-tempest' % lpar_id):
            continue

        if lpar_w.state in [pvm_bp.LPARState.RUNNING,
                            pvm_bp.LPARState.OPEN_FIRMWARE]:
            power.power_off(lpar_w, host_uuid, force_immediate=True)
        actual_lpar_wraps.append(lpar_w)

    return actual_lpar_wraps


def find_and_remove_scsi_mappings(adpt, lpar_wraps):
    """Finds and removes the scsi mappings off a VIOS for a set of LPARs."""
    # Only one vios
    vios_wrap = pvm_vios.VIOS.get(adpt,
                                  xag=[pvm_vios.VIOS.xags.SCSI_MAPPING])[0]
    to_del_ids = [lpar_w.id for lpar_w in lpar_wraps]

    # Find the maps to delete
    scsi_maps_to_del = []
    for scsi_map in vios_wrap.scsi_mappings:
         if scsi_map.client_adapter.lpar_id in to_del_ids:
             scsi_maps_to_del.append(scsi_map)

    # remove and update the VIOS
    for map_to_del in scsi_maps_to_del:
        vios_wrap.scsi_mappings.remove(map_to_del)
    vios_wrap.update()

    # Return the deleted mappings
    return scsi_maps_to_del


def remove_backing_storage(adpt, scsi_maps):
    """Deletes the backing storage for the scsi maps."""
    try:
        # Find the SSPs and clean out
        ssp_resp = adpt.read(pvm_stor.SSP.schema_type)
        ssp_feed = pvm_stor.SSP.wrap(ssp_resp)
        for ssp in ssp_feed:
            print "Shared Storage Pool %s" % ssp.name
            lu_to_del = []

            # Find all the LU's to delete
            for scsi_map in scsi_mappings:
                for lu in ssp.logical_units:
                    if scsi_map.backing_storage.udid == lu.udid:
                        lu_to_del.append(lu)

            # Now remove the LU's from the list
            for lu in lu_to_del:
                ssp.logical_units.remove(lu)
            ssp.update()
            print "Shared Storage Pool update complete"
    except Exception as ssp_e:
        # This can occur if other nodes in the cloud still use a disk.
        print "Error with SSP Cleaning.  Non-blocking."


def delete_lpars(adpt, lpar_wraps):
    for lpar_wrap in lpar_wraps:
        try:
            lpar_wrap.delete()
        except Exception:
            print "Non blocking VM delete error."


def main():
    try:
        adpt = adapter.Adapter(adapter.Session())
        ms = pvm_ms.System.wrap(adpt.read(pvm_ms.System.schema_type))[0]

        # Find the VMs that are paired to this system.
        lpar_wraps = find_all_target_vms(adpt, ms.uuid)

        # Find and remove the SCSI mappings
        scsi_mappings = find_and_remove_scsi_mappings(adpt, lpar_wraps)

        # Delete the backing storage
        remove_backing_storage(adpt, scsi_mappings)

        # And end with a delete of the VMs
        delete_lpars(adpt, lpar_wraps)
    except Exception as e:
        print str(e)
        print "Error during clean up.  Non-blocking"


# Run the cleaner
main()
