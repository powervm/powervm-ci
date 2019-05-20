#!/bin/bash -xe

usage () {
    echo "usage: ./prep_devstack.sh [-p pypowervm_patch_list] [-n nova_patch_list] [-d driver] [-fh]"
    echo "    -p pypowervm_patch_list (optional): List of patches to be applied to pypowervm. Valid values"
    echo "        are a comma or whitespace separated list of pypowervm change numbers or"
    echo "        the special value 'none' which will not apply any patches. If the -p flag is"
    echo "        not used, no patches will be applied."
    echo "    -d driver (optional): Which nova driver to use. Valid options are 'in-tree' or"
    echo "        'out-of-tree'. If the -d flag is not used, it will use the out-of-tree"
    echo "        driver by default."
    echo "    -f (optional): Force flag. This will skip loading patches to the openstack"
    echo "        projects (unless nova_patch_list is used). It will use the latest code"
    echo "        for the branch being tested. The branch will default to master unless"
    echo "        ZUUL_BRANCH is specified."
    echo "    -h (optional): Display this help menu."
}

get_latest_patch() {
    # get_latest_patch repos changenum
    #
    # Get the commit hash and refspec for the latest patch set of a given change set.
    #
    # param repos: A gerrit repository, e.g. https://review.openstack.org/openstack/nova
    # param changenum: A gerrit change set number, e.g. 391288
    # stdout: A git commit and refspec, pipe-delimited, e.g.:
    #         f7d340f897695e38358a0aae29400ebd38f6381a|refs/changes/88/391288/3
    # on fail: error exit
    repos=$1
    changenum=$2

    # git ls-remote lists "commit   refs/changes/x/changenum/patchnum", e.g.:
    # f7d340f897695e38358a0aae29400ebd38f6381a        refs/changes/88/391288/3
    # sort by the 5th '/'-delimited field, numerically, in reverse
    # awk print the first field of the first record, pipe, the second field
    result=`git ls-remote $repos "*/$changenum/*" | sort -t/ -k5 -rn | awk 'NR==1 {print $1"|"$2}'`
    if ! [ $result ]; then
        echo "Couldn't find change set $changenum in repository $repos"
        exit -1
    fi
    echo "$result"
    return 0
}

driver=outoftree
FORCE=false
pypowervm_patch_list=
VSCSI_RUN=${VSCSI_RUN:-false}
while getopts ":p:d:fh" opt; do
    case $opt in
        d)
            if [[ $OPTARG == 'in-tree' ]]; then
                driver=intree
            elif [[ $OPTARG == 'out-of-tree' ]]; then
                :
            else
                usage
            fi
            ;;
        f)
            FORCE=true
            ;;
        p)
            if ! [[ $OPTARG == 'none' ]]; then
                pypowervm_patch_list=$OPTARG
            fi
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage
            exit 1
            ;;
    esac
done

# Source ini-config for iniset and localconf_set use
source /opt/stack/devstack/inc/ini-config

# Print the neo hostname
neo_host=$(sudo /usr/sbin/rsct/bin/getRTAS | sed -n 's/.*HscHostName=\(neo[^;]*\);.*/\1/p')
echo "Running on neo host: $neo_host"

# Help out the guy running this manually. If the -f flag was passed, master
# branch will be used for all openstack repos and no change will be checked
# out.
if $FORCE; then
    ZUUL_BRANCH=${ZUUL_BRANCH:-master}
else
    counter=0
    for v in ZUUL_BRANCH ZUUL_PROJECT BASE_LOG_PATH; do
        counter=`expr $counter + 1`
        if ! [ $"$v" ]; then
            echo '$'$v' not set.  Run with -f to force.'
            exit -1
        fi
        echo "$counter= $v "
    done
fi

# Copy the correct version of local.conf into devstack
conf_file=local.conf
patching_file=patching.conf
if $VSCSI_RUN; then
    conf_file=vscsi.local.conf
    patching_file=vscsi.patching.conf
fi
echo "ZUUL_BRANCH is $ZUUL_BRANCH"
cp /opt/stack/powervm-ci/devstack/$ZUUL_BRANCH/$driver/$conf_file \
   /opt/stack/devstack/local.conf

# Set the nova instance_name_template to facilitate cleanup
vm_id=`/opt/stack/powervm-ci/scripts/my_vm_id.sh`
template="pvm$vm_id-%(display_name).11s-%(uuid).8s"
localconf_set "/opt/stack/devstack/local.conf" "post-config" "\$NOVA_CONF" \
              "DEFAULT" "instance_name_template" "$template"

# Logs setup
mkdir -p /opt/stack/logs

# Setting Storage=persistent causes journald to store the journals in
# /var/log/journal instead of /run/log/journal. There wasn't enough space
# in /run/ for the journals to reside there.
sudo sed -i 's/^#Storage=.*$/Storage=persistent/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald.service

# This list is built from prepare_node_powervm.sh
for proj in ceilometer ceilometer-powervm cinder devstack glance horizon keystone networking-powervm neutron nova nova-powervm requirements; do
    cd /opt/stack/$proj
    git fetch
    git checkout $ZUUL_BRANCH
    git pull
done

# Checkout latest tempest
cd /opt/stack/tempest
git checkout master
git pull

if ! $FORCE || [[ $ZUUL_PROJECT && $BASE_LOG_PATH ]]; then
    # Apply upstream change
    cd /opt/stack/${ZUUL_PROJECT##*/}
    git pull https://review.openstack.org/$ZUUL_PROJECT refs/changes/$BASE_LOG_PATH --no-edit
fi

# Openstack project patching
while read line; do
    echo "$line" | egrep -q '^\s*(#.*)?$' && continue
    # Extract the repo and change list information
    repo=${line%:*}
    change_list=${line#*:}
    repo_url=https://review.openstack.org/$repo/
    project=${repo#*/}
    cd /opt/stack/$project

    # Apply the list of changes to the project
    for change in $(echo $change_list | sed "s/,/ /g"); do
        patch=`get_latest_patch "$repo_url" "$change"`
        refspec=${patch#*|}
        commit=${patch%|*}
        # Only apply the patch if it's not in the chain of the change set we're testing.
        if git log --no-merges --pretty=format:%H origin/$ZUUL_BRANCH..HEAD | grep -q $commit; then
            echo "Skipping $project commit $commit of change $i because it's already in the commit chain"
            echo "or is not a $project change."
        else
            echo "Applying $repo ref $refspec of change set $i (commit $commit)"
            git fetch "$repo_url" "$refspec"
            git cherry-pick --keep-redundant-commits FETCH_HEAD
        fi
    done
done < /opt/stack/powervm-ci/devstack/$ZUUL_BRANCH/$driver/$patching_file

pypowervm_version=$(awk -F= '$1=="pypowervm" {print $NF}' /opt/stack/requirements/upper-constraints.txt)

# If running on ocata the session config patch needs to be applied.
# TODO: Once pypowervm 1.1.2 or greater is being used for all scenarios, this can
# removed from the script.
if $(dpkg --compare-versions $pypowervm_version lt 1.1.2); then
    pypowervm_patch_list+=,5112
fi

# Reinstall pypowervm with the list of patches in pypowervm_patch_list applied
if [ ! -z "$pypowervm_patch_list" ]; then
    cd /opt/stack/pypowervm/
    git clean -f
    git reset --hard
    git fetch
    git checkout $pypowervm_version
    PYPOWERVM_REPO=$(git remote get-url origin)
    for i in $(echo $pypowervm_patch_list | sed "s/,/ /g"); do
        patch=`get_latest_patch "$PYPOWERVM_REPO" "$i"`
        refspec=${patch#*|}
        commit=${patch%|*}
        echo "Applying pypowervm ref $refspec of change set $i (commit $commit)"
        git fetch "$PYPOWERVM_REPO" $refspec
        git cherry-pick --keep-redundant-commits FETCH_HEAD
    done
    cd -
    sudo pip install -e /opt/stack/pypowervm

    # Remove pypowervm from requirements. This will prevent our patched version
    # of pypowervm from being overwritten when stacking.
    for f in requirements/upper-constraints.txt requirements/global-requirements.txt nova/requirements.txt nova-powervm/requirements.txt; do
        if [[ -f /opt/stack/$f ]]; then
            sudo sed -i '/pypowervm/d' /opt/stack/$f
        fi
    done
fi

# Set /etc/environment as the environment file location for openstack services.
# /etc/environment holds a variable, PYPOWERVM_SESSION_CONFIG, that contains the path
# for the session configuration needed for remote pypowervm to work. This is limited
# to branches using systemd instead of screen for openstack services (pike and newer).
if [ "$ZUUL_BRANCH" != "stable/ocata" ]; then
    sudo mkdir -p /etc/systemd/system/
    pvm_services="pvm-q-sea-agt pvm-q-sriov-agt n-cpu pvm-ceilometer-acompute"
    for service in $pvm_services; do
        iniset -sudo "/etc/systemd/system/devstack@$service.service" "Service" "EnvironmentFile" "-/etc/environment"
    done
fi

# Disable SMT while stacking
# POWER CPUs have lots of threads.  Devstack likes to use all of the threads
# it can.  But if we have a SMT-8 CPU with 4 cores, that could be 32 threads.
# This can lead devstack to spawn 32 metadata threads.  There are ways to
# limit this behavior in devstack, but it doesn't work for all of the various
# processes.
#
# Its best to just turn off the cores and bring it down to SMT-1.  We lose
# some performance, but get a MUCH smaller amount of used memory, which is good
# for these test runs.
sudo ppc64_cpu --smt=off
# Stack
cd /opt/stack/devstack
TERM=vt100 ./stack.sh
# Re-enable SMT
sudo ppc64_cpu --smt=on

# Normally the hosts get discovered when stack runs discover_hosts. However the
# discovery sometimes fails to find any hosts at that point. Running discover_hosts
# a second time here should find any hosts that weren't discovered initially. We thought that the
# issue would be alleviated by https://review.openstack.org/#/c/488381/ however that was not the
# case.
# TODO: Determine why the compute host isn't being discovered when stacking.
nova-manage cell_v2 discover_hosts

source /opt/stack/devstack/openrc admin admin

# NOTE: The networks will not be created for the in-tree pike branch. The
# functionality for in-tree pike is very limited and will not work with the
# networks below.
if [ "$driver" == "intree" ] && [ "$ZUUL_BRANCH" == "stable/pike" ]; then
    # Include additional skipped tests for in-tree pike
    cat /opt/stack/powervm-ci/tempest/pike_it_blacklist.txt >> /opt/stack/powervm-ci/tempest/in_tree_blacklist.txt
else
  # Create unique VLAN for each network
  public_seg_id=$(expr $vm_id + 1000)
  private_seg_id=$(expr $vm_id + 2000)

  # Create public and private networks for the tempest runs
  # TODO: Ideally we should have devstack creating our networks for us
  # based on our local.conf files. This can be removed if we get working
  # devstack-created networks.
  openstack network create public --share --external --provider-network-type vlan --provider-physical-network default --provider-segment $public_seg_id --project-domain admin
  openstack subnet create public-subnet --gateway 192.168.2.254 --allocation-pool start=192.168.2.100,end=192.168.2.200 --network public --no-dhcp --subnet-range 192.168.2.0/24
  openstack network create private --share --provider-network-type vlan --provider-physical-network default --provider-segment $private_seg_id --project-domain admin
  openstack subnet create private-subnet --gateway 192.168.3.254 --allocation-pool start=192.168.3.100,end=192.168.3.200 --network private --no-dhcp --subnet-range 192.168.3.0/24
fi

exit 0
