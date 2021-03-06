#!/bin/bash

# Copyright 2016, 2018 IBM Corp.
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

# Print args to stderr and exit with failure
function bail {
  echo "$@" >&2
  exit 255
}

# Base directory of powervm-ci project is parent of pwd
conf_dir=`realpath ${0%/*}/../tempest`
[[ -d $conf_dir ]] || bail "Config directory $conf_dir not found!"
CONF_DEFAULT=$conf_dir/os_ci_tempest.conf

CMD=${0##*/}
function usage {
  cat <<EOU
Usage: $CMD [-D] [-v] [-p] [-c config] [-o outfile.html]

  -c config           Path to config file for this script (not for
                      tempest).
                      Default: $CONF_DEFAULT
  -D                  Turn on debug trace.
  -o /path/to/reports Directory in which to store test results.
                      Conf option: \$OUTPATH
  -p                  Prep only.  Ensures the stack contains the
                      appropriate image, flavors, and network.  Creates
                      a complete tempest.conf.  Generates the list of
                      tests to be run.  The locations of these files are
                      printed at the end of the program.  (Note that a
                      full run (without -p) will generate new copies of
                      these files; there's no way to use the files from
                      a prep-only run.)
  -v                  Verbose mode (reports e.g. which tests will be
                      run/skipped).

Exit codes:
  0    Tests passed
  1    Tests failed
  255  Something went wrong in this script
EOU
  exit 255
}

function verb {
    ### verb arg [...]
    #
    # Print args to stderr if VERBOSE enabled.
    ###
    [ $VERBOSE ] && ! [ $DEBUG ] && echo "$@" >&2
}

function check_exe {
    ### check_exe exename
    #
    # Verify existence and executability of program named by first arg.
    ###
    exe=$1
    which $exe >/dev/null 2>&1 || bail "$exe not found or not executable."
}

function validate_checksum {
    ### validate_checksum checksum
    #
    # Ensures that the 'checksum' argument is a valid MD5 hash
    # comprising exactly 32 lowercase hex digits.  Exits the program if
    # the checksum is empty or invalid.
    ###
    checksum=$1
    [ "$checksum" ] || bail "Empty checksum."
    echo "$checksum" | egrep -q '^[0-9a-f]{32}$' || bail "Invalid checksum argument '$checksum' - expected 32 lowercase hex digits."
    return 0
}

function get_obj_vals {
    ### get_obj_vals type name field [field...]
    #
    # If not already set, retrieves the specified field value(s) from
    # openstack object of type 'type' (e.g. 'network', 'image',
    # 'flavor', etc.) with name 'name' and sets global variable(s)
    # accordingly.  For example:
    #
    #     get_obj_vals image foo id size
    #
    # ...will result in global variable $image_foo_id to the 'foo'
    # image's UUID; and $image_foo_size to its size in bytes.
    #
    # LIMITATIONS:
    # o The 'type' and 'name' variables are restricted to characters
    # valid for shell variable names.
    # o To force rediscovery of already-discovered values, the consumer
    # must clear the variable(s) prior calling this function.
    ###
    typ=$1
    name=$2
    shift 2
    discover=
    cols=
    for col in "$@"; do
        eval val=\$${typ}_${name}_${col}
        # If (any) value not set, discovery is required
        [ -z $val ] && discover=1
        cols+=" -c $col"
    done
    if [ $discover ]; then
        eval `openstack "$typ" show $cols -f shell --prefix "${typ}_${name}_" "$name"`
    fi
}

function discover_and_set_id {
    ### discover_and_set_id tempest_conf objtype objname section varname
    #
    # Discovers the UUID of the 'objtype' object named 'objname' and
    # sets the 'varname' value in section 'section' of tempest.conf file
    # 'tempest_conf' accordingly.
    #
    # Error exit if the UUID can't be discovered or the tempest.conf
    # edit fails.
    ###
    tempest_conf=$1
    objtype=$2
    objname=$3
    section=$4
    varname=$5

    # All values required, nonempty
    [ "$tempest_conf" ] || bail "discover_and_set_id: tempest_conf is required"
    [ "$objtype" ] || bail "discover_and_set_id: objtype is required"
    [ "$objname" ] || bail "discover_and_set_id: objname is required"
    [ "$section" ] || bail "discover_and_set_id: section is required"
    [ "$varname" ] || bail "discover_and_set_id: varname is required"

    # Retrieve the UUID of the object
    get_obj_vals "$objtype" "$objname" id
    eval varid=\$${objtype}_${objname}_id
    # Set it in tempest.conf
    iniset "$tempest_conf" "$section" "$varname" "$varid"
}

function find_img_lu_for_checksum {
    ### find_img_lu_for_checksum var_to_set insum
    #
    # If the SSP already contains an appropriately-named* image LU whose
    # MD5 checksum matches the 'insum' parameter, this function extracts
    # the image name from that LU name and assigns it to the variable
    # named in 'var_to_set'.
    #
    # *An "appropriate" image LU name is of the format
    # 'image_{name}_{checksum}', where {name} is the name of the glance
    # image from which it was created; and {checksum} is the
    # 32-character MD5 hash of the image content.
    ###
    var_to_set=$1
    insum=$2
    validate_checksum "$insum"

    verb "Looking for an existing Image LU with checksum '$insum'"
    while read luname; do
        sum=`echo $luname | awk -F_ '/^image_/ {print $NF}'`
        [[ $? -eq 0 ]] && [ "$sum" ] || continue
        if [[ "$sum" == "$insum" ]]; then
            verb "Found matching LU '$luname'."
            imgname=${luname#*_}
            imgname=${imgname%_*}
            eval $var_to_set="$imgname"
            return 0
        fi
    done < <(pvmctl lu list -d name --where 'LogicalUnit.lu_type=VirtualIO_Image' --hide-label)
    verb "No matching Image LU found."
    return 1
}

function find_glance_image {
    ### find_glance_image var_to_set checksum [name]
    #
    # Finds a glance image with the specified checksum and possibly
    # name.  If found, the name is assigned to the variable named in
    # 'var_to_set' and the function returns success; otherwise the
    # variable is not set and the function returns failure.
    ###
    var_to_set=$1
    checksum=$2
    inname=$3

    validate_checksum "$checksum"

    msg="Looking for an existing glance image with checksum '$checksum'"
    [ "$inname" ] && msg+=" and name '$inname'"
    verb "$msg"
    while read outname; do
        if [ -z "$inname" ] || [[ "$inname" == "$outname" ]]; then
            verb "Found existing glance image '$outname'."
            eval $var_to_set="$outname"
            return 0
        fi
    done < <(openstack image list --property checksum="$checksum" -f value -c Name)
    verb "No matching glance image found."
    return 1
}

function prep_glance_image {
    ### prep_glance_image imgname imgfile tempest_conf varname
    #
    # By the time this method is finished, the image named 'imgname'
    # exists in glance, and its UUID is registered in tempest.conf file
    # 'tempest_conf' under the key specified by 'varname' (i.e.
    # 'image_ref' or 'image_ref_alt').  If glance doesn't already
    # contain an image of the specified name, 'imgfile' is uploaded.  If
    # you're sure the image already exists in glance, you may explicitly
    # pass the empty string ("") for the imgfile parameter.
    #
    # LIMITATIONS:
    # o If a glance image of the specified name already exists, we make
    # no attempt to verify that its content is the same as the specified
    # image file.
    ###
    imgname=$1
    imgfile=$2
    tempest_conf=$3
    varname=$4

    # Check params
    [ "$imgname" ] || bail "prep_glance_image: imgname is required."
    if [ "$imgfile" ]; then
        # If image filename was passed, make sure it exists
        [[ -f "$imgfile" ]] || bail "Image file '$imgfile' not found."
    fi
    [ "$varname" ] || bail "prep_glance_image: varname (config file key) is required."

    # Cache the size here too - this can save us an extra query later
    get_obj_vals image "$imgname" id size
    eval imgid=\$image_${imgname}_id
    if [ -z "$imgid" ]; then
        # Need to upload the image
        verb "Uploading $imgfile to glance"
        [ $VERBOSE ] && progress='--progress' || progress=
        glance --os-image-api-version 2 image-create --file "$imgfile" $progress --disk-format=raw --container-format=bare --property name="$imgname" --property visibility=public || bail "Failed to create image '$imgname' from file '$imgfile'!"
    fi

    # Set the UUID in the tempest.conf
    discover_and_set_id "$tempest_conf" image "$imgname" compute "$varname"
}

function prep_flavor {
    ### prep_flavor name mem_mb disk_gb cpu tempest_conf varname
    #
    # By the time this method is finished, a flavor named 'name' exists,
    # and its UUID is registered in tempest.conf file 'tempest_conf'
    # under the key specified by 'varname' (i.e. 'flavor_ref' or
    # 'flavor_ref_alt').  If a flavor of the specified name does not
    # already exist, it is created with the memory, disk, and CPU
    # settings specified.  The 'mem_mb' (RAM size in megabytes),
    # 'disk_gb' (root disk size in gigabytes), and 'cpu' (number of
    # virtual CPUs) parameters are all positive integers.  If you're
    # sure the named flavor already exists, you may explicitly pass the
    # empty string ("") for 'mem_mb', 'disk_gb', and 'cpu'.
    #
    # LIMITATIONS:
    # o If a flavor of the specified name already exists, we make no
    # attempt to verify that its settings are the same as those
    # specified.
    ###
    flvname=$1
    mem_mb=$2
    disk_gb=5
    cpu=$4
    tempest_conf=$5
    varname=$6

    # Check params
    [ "$flvname" ] || bail "prep_flavor: flavor name is required."
    [ "$varname" ] || bail "prep_flavor: varname (config file key) is required."

    get_obj_vals flavor "$flvname" id
    eval flvid=\$flavor_${flvname}_id
    if [ -z "$flvid" ]; then
        # Need to create the flavor
        # First ensure valid flavor specs were passed
        numre='^[1-9][0-9]*$'
        numre2='^[0-9][0-9]*$'
        [[ "$mem_mb" =~ $numre ]] || bail "prep_flavor: mem_mb '$mem_mb' not valid - must be a positive integer."
        [[ "$disk_gb" =~ $numre2 ]] || bail "prep_flavor: disk_gb '$disk_gb' not valid - must be a positive integer or zero."
        [[ "$cpu" =~ $numre ]] || bail "prep_flavor: vcpu count '$cpu' not valid - must be a positive integer."
        verb "Creating flavor '$flvname' with $mem_mb MB RAM, $disk_gb GB disk, and $cpu vcpu."
        nova flavor-create "$flvname" auto "$mem_mb" "$disk_gb" "$cpu" || bail "Failed to create flavor '$flvname'!"
    fi

    # Set the UUID in tempest.conf
    discover_and_set_id "$tempest_conf" flavor "$flvname" compute "$varname"
}

function create_network {
    ### create_network name external ap_start ap_end cidr gateway vlan_mod
    #
    # By the time this method is finished, a network with the specified
    # 'name' exists.  It is internal or external based on the 'external'
    # parameter ('True' or 'False').  If the network doesn't already
    # exist, it is created, along with its subnet.  The subnet is
    # created with the allocation pool range specified by 'ap_start' and
    # 'ap_end'.
    #
    # The CIDR is passed in to tell neutron what the full subnet is.  The
    # gateway is a faux gateway IP address that is outside of the allocation
    # pool.  A vlan modifier is also passed in, which is used in conjunction
    # with the VM ID.  The VLAN that gets used for the neutron network is
    # set to (VM ID + vlan modifier).  This is needed for the simulated
    # Tempest Nesting support that the PowerVM driver is using.
    #
    # LIMITATIONS:
    # o If a network of the specified 'name' already exists, no attempt
    # is made to ensure that it has the proper attributes; namely:
    #   - That it has the correct VLAN ID.
    #   - That it is internal/external.
    #   - That it has a subnet at all.
    #   - That its subnet has the expected network address, gateway, and
    #   allocation pool range.
    ###
    net_name=$1
    external=$2
    ap_start=$3
    ap_end=$4
    cidr=$5
    gateway=$6
    vlan_mod=$7

    vm_id=`awk -F= '/^partition_id=/ {print $2}' /proc/ppc64/lparcfg`
    [ $vm_id ] || bail "Unable to discover my VM ID."

    # Add vlan_mod (the modifier) to create unique VLAN for devstack network
    vlan_id=$(expr $vm_id + $vlan_mod)

    get_obj_vals network "$net_name" id
    eval netid=\$network_${net_name}_id
    if [ -z "$netid" ]; then
        # Network needs to be created
        # We need the admin tenant (project) UUID
        get_obj_vals project admin id
        verb "Creating network '$net_name'"
        neutron net-create "$net_name" --router:external "$external" --provider:physical_network default --provider:network_type vlan --provider:segmentation_id "$vlan_id" --tenant-id "$project_admin_id" || bail "Failed to create '$net_name' network!"
        verb "Adding subnet $cidr"
        neutron subnet-create --name "${net_name}-subnet" --gateway "$gateway" --allocation-pool start="$ap_start",end="$ap_end" "$net_name" "$cidr" || bail "Failed to create subnet for '$net_name' network!"
    fi
}

function prep_public_network {
    ### prep_public_network tempest_conf
    #
    # By the time this method is finished, a network called 'public'
    # exists, and its UUID is registered in tempest.conf file
    # 'tempest_conf' under the key 'public_network_id' in the
    # '[network]' section.  If the network doesn't already exist, it and
    # its subnet are created.
    #
    # LIMITATIONS:
    # o If a network named 'public' already exists, no attempt is made
    # to ensure that it has the proper attributes; namely:
    #   - That it is external.
    #   - That it has a subnet at all.
    #   - That its subnet has the expected network address and gateway.
    ###
    tempest_conf=$1
    net_name=public

    create_network "$net_name" "True" "192.168.2.100" "192.168.2.200" "192.168.2.0/24" "192.168.2.254" 1000

    # Set the UUID in tempest.conf
    discover_and_set_id "$tempest_conf" network "$net_name" network public_network_id
}

function create_primer_lpar {
    ### create_primer_lpar flavor image net_id lparname imgsum
    #
    # Creates an LPAR with the specified lparname on the network identified by
    # net_id using the specified flavor (name or ID) and image.  Waits, polling
    # the SSP, until the LU has been created, indicating that the upload has
    # begun.  The imgsum parameter is the MD5 sum of the image in question.
    # This is used to ensure we find the correct LU.
    ###
    flavor=$1
    imagename=$2
    net_id=$3
    lparname=$4
    imgsum=$5

    nova boot --flavor "$flavor" --image "$imagename" --nic net-id="$net_id" "$lparname" || bail "Failed to create primer LPAR."

    while ! find_img_lu_for_checksum not_used "$imgsum"; do
        sleep 1
        # TODO: Should we have a timeout?
    done
}

function prep_for_tempest {
    ### prep_for_tempest tempest_conf
    #
    # Gets the current devstack ready to run tempest:
    # o Ensures glance images are in place and their UUIDs are
    # registered in tempest.conf.
    # o Ensures flavors are in place and their UUIDs are registered in
    # tempest.conf.
    # o Ensures public network is in place and its UUID is registered in
    # tempest.conf.
    # o Ensures the proper admin tenant ID is registered in
    # tempest.conf.
    ###
    tempest_conf=$1

    flvname1=CI_flv_1
    flvname2=CI_flv_2

    # Set up for openstack commands
    source "$OPENRC" admin admin

    # Set up for editing tempest configuration
    source /opt/stack/devstack/inc/ini-config

    verb "Calculating MD5 hash of image file '$IMGFILE'."
    imgsum=`md5sum "$IMGFILE" | cut -c -32`

    # See if an appropriate image LU already exists.
    lu_needed=
    find_img_lu_for_checksum imgname "$imgsum"
    [ "$imgname" ] || lu_needed=1

    # See if an appropriate glance image already exists.  If an image LU
    # was found, the glance image's name must match, and this call will
    # overwrite $imgname with the same value.  Otherwise, we'll settle
    # for any glance image with the right checksum.
    find_glance_image imgname "$imgsum" "$imgname"

    # If no existing glance image found, we'll have to upload it.
    # Minimize the probability of colliding with an existing image
    # (same name, but wrong size/checksum) by generating a
    # probably-unique default name.  Attach no significance to the
    # digits in this name; the PID/PPID only indicate the first process
    # to reach this point.
    [ "$imgname" ] || imgname="CI_img_$$_$PPID"

    # Upload the image if necessary, and extract its ID and size.  The
    # ID is registered in tempest.conf by this call; the size will be
    # used to generate flavor specs below.
    prep_glance_image "$imgname" "$IMGFILE" "$tempest_conf" image_ref
    # Tempest uses two image ID references, even if they're the same.
    prep_glance_image "$imgname" "" "$tempest_conf" image_ref_alt

    # Set the flavor's disk size to 0.  This is a special value that
    # tells Nova to create the disk as the size of the image itself.
    diskgb=0

    # Ensure flavors are created and registered
    prep_flavor "$flvname1" "$FLVMEM" "$diskgb" "$FLVCPU" "$tempest_conf" flavor_ref
    prep_flavor "$flvname2" "$FLVMEM" "$diskgb" "$FLVCPU" "$tempest_conf" flavor_ref_alt

    # Ensure public network exists and is registered
    prep_public_network "$tempest_conf"

    # Ensure private network exists
    create_network "private" "False" "192.168.3.100" "192.168.3.200"  "192.168.3.0/24" "192.168.3.254" 2000

    # Discover and register the admin tenant ID
    discover_and_set_id "$tempest_conf" project admin identity admin_tenant_id

    # Generate api extension lists
    generate_extensions "$tempest_conf"

    # At this point, we should create the image LU if necessary.  We do
    # this by creating a VM with the appropriate image.  Even though the
    # nova boot is asynchronous, the nova-powervm driver will upload the
    # image LU with semantics that ensure subsequent attempts to create
    # a VM will wait appropriately until it is done.  So we can kick off
    # the tests "while" the instance is being created.
    if [ "$lu_needed" ]; then
        get_obj_vals network private id
        create_primer_lpar "$flvname1" "$imgname" "$network_private_id" ssp_primer "$imgsum"
    fi  # lu_needed

    # The LU may still be uploading, but we're ready to start tests.
    return 0
}

function generate_extensions {
    conf_file=$1
    extensions=$(openstack extension list --network -c Alias -f value | paste -s -d, -)
    iniset "$conf_file" "network-feature-enabled" "api_extensions" "$extensions"
}

## main Main MAIN

# Process command args

OPTIND=1
while getopts "c:Do:pv" opt; do
  case "$opt" in
    c) CONF=$OPTARG                ;;
    D) DEBUG=1                     ;;
    o) OUTPATH_ARG=$OPTARG         ;;
    p) PREP_ONLY=1                 ;;
    v) VERBOSE=1                   ;;
    *) usage                       ;;
  esac
done

# Set trace if DEBUG requested
[ $DEBUG ] && set -x

# Source config vars
CONF=${CONF:-$CONF_DEFAULT}
. "$CONF" || bail "Couldn't source config file $CONF"

# Output HTML file path.
# Command line takes precedence; then config file; then default.
OUTPATH=${OUTPATH_ARG:-${OUTPATH:-/opt/stack/logs}}
# Resolve the directory, because we cd later
if ! [[ -d "$OUTPATH" ]]; then
    mkdir -p "$OUTPATH" || bail "Failed to create output directory $OUTPATH."
fi
ofbase=`realpath $OUTPATH`/powervm_os_ci
OUTFILE_HTML=${ofbase}.html
SUBUNIT_RESULTS=${ofbase}.subunit

# Location of the tempest repository
TEMPEST_DIR=`realpath ${TEMPEST_DIR:-/opt/stack/tempest}`

# Verify existence of tempest at $TEMPEST_DIR
[[ -d $TEMPEST_DIR ]] || bail "$TEMPEST_DIR: no such directory."

# Absolute path to the tempest.conf file to use.
TEMPEST_CONF=`realpath ${TEMPEST_CONF:-"/opt/stack/tempest/etc/tempest.conf"}`

# Make sure tempest.conf exists
[[ -f "$TEMPEST_CONF" ]] || bail "Couldn't find tempest.conf at $TEMPEST_CONF"

# Temporary tempest.conf to generate/populate
TEMPEST_CONF_GEN=`mktemp /tmp/tempest.conf.XXX`
cp -f "$TEMPEST_CONF" "$TEMPEST_CONF_GEN"

# Location of installed tempest.conf file (the one tempest will run with).
TEMPEST_CONF_INST=${TEMPEST_DIR}/etc/tempest.conf

# Location of openrc file (to enable openstack commands)
OPENRC=${OPENRC:-/opt/stack/devstack/openrc}

# Location of image to upload to glance
IMGFILE=${IMGFILE:-/home/jenkins/vm_images/base_os.img}

# Flavor specs.  (For now, one set of specs goes for both flavors.)
FLVMEM=${FLVMEM:-512}
FLVCPU=${FLVCPU:-1}

# Verify existence and executability of programs
check_exe stestr
check_exe subunit2html
check_exe subunit-stats
check_exe openstack
check_exe glance
check_exe neutron
check_exe nova
check_exe md5sum
check_exe pvmctl

# Remove temp files and restore original tempest.conf on any exit.
function cleanup {
  if [[ -f "${TEMPEST_CONF_INST_BAK}" ]]; then
      mv -f "${TEMPEST_CONF_INST_BAK}" "${TEMPEST_CONF_INST}"
  fi
  if [ $DEBUG ]; then
      SUBUNIT_RESULTS=${SUBUNIT_RESULTS:-Not generated}
      echo "Subunit results: $SUBUNIT_RESULTS"
  fi
}
[ $PREP_ONLY ] || trap cleanup EXIT

# Prep our devstack and tempest.conf.
prep_for_tempest "$TEMPEST_CONF_GEN"

MVCMD="mv -f $TEMPEST_CONF_GEN $TEMPEST_CONF_INST"
RUNCMD="stestr run --blacklist-file $BLACK_LIST --concurrency=4 --subunit"
if [ -n "$WHITE_LIST" ];then
    RUNCMD="stestr run --whitelist-file $WHITE_LIST --concurrency=4 --subunit"
fi

if [ $PREP_ONLY ]; then
    echo
    echo "=============================================="
    echo "Prep-only option was specified; stopping here."
    echo
    echo "Generated tempest config: $TEMPEST_CONF_GEN"
    echo
    echo "To run this suite manually, execute:"
    echo "  $MVCMD"
    echo "  $RUNCMD"
    echo "=============================================="
    exit 0
fi

# Location for backup of original tempest.conf
TEMPEST_CONF_INST_BAK=`mktemp ${TEMPEST_DIR}/etc/tempest.conf.bak.XXX`

# Back up the original tempest.conf
if [[ -f "$TEMPEST_CONF_INST" ]]; then
  cp -f "$TEMPEST_CONF_INST" "${TEMPEST_CONF_INST_BAK}"
fi

verb "Installing generated tempest.conf to $TEMPEST_CONF_INST"
$MVCMD

# Export tempest single test timeout
export OS_TEST_TIMEOUT

cd $TEMPEST_DIR
stestr init

# Print tests being run and skipped (if blacklist) and keep count.
if [ -n "$WHITE_LIST" ]; then
    run_list=$(stestr list --whitelist-file $WHITE_LIST)
else
    run_list=$(stestr list --blacklist-file $BLACK_LIST)
    skip_list=$(stestr list --whitelist-file $BLACK_LIST)
fi
for line in $run_list; do
    verb "Will RUN $line"
    count=$((count+1))
done
for line in $skip_list; do
    verb "Will SKIP $line"
done

# Print total number of tests being run
echo "Running $count tests..."

# Run it!
verb "$RUNCMD"
$RUNCMD > $SUBUNIT_RESULTS

subunit2html $SUBUNIT_RESULTS $OUTFILE_HTML

echo
echo "=============================================="
subunit-stats $SUBUNIT_RESULTS
RC=$?
echo "Completed in $SECONDS seconds."
echo "HTML report in $OUTFILE_HTML"
echo "Subunit results in $SUBUNIT_RESULTS"
echo "=============================================="

exit $RC
