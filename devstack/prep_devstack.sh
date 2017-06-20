#!/bin/bash -xe

usage () {
    echo "usage: ./prep_devstack.sh [-p pypowervm_patch_list] [-n nova_patch_list] [-d driver] [-fh]"
    echo "    -p pypowervm_patch_list (optional): List of patches to be applied to pypowervm. Valid values"
    echo "        are a comma or whitespace separated list of pypowervm change numbers or"
    echo "        the special value 'none' which will not apply any patches. If the -p flag is"
    echo "        not used, no patches will be applied."
    echo "    -n nova_patch_list (optional): List of patches to be applied to nova. Valid values"
    echo "        are a comma or whitespace separated list of nova change numbers or"
    echo "        the special value 'none' which will not apply any patches. If the -n flag"
    echo "        is unused, no patches will be applied."
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

in_tree=false
conf_file=outoftree.local.conf
FORCE=false
pypowervm_patch_list=
nova_patch_list=

while getopts ":n:p:d:fh" opt; do
    case $opt in
        d)
            if [[ $OPTARG == 'in-tree' ]]; then
                in_tree=true
                conf_file=intree.local.conf
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
        n)
            if ! [[ $OPTARG == 'none' ]]; then
                nova_patch_list=$OPTARG
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

# Help out the guy running this manually
if $FORCE; then
    ZUUL_BRANCH=${ZUUL_BRANCH:-master}
else
    for v in ZUUL_BRANCH ZUUL_PROJECT BASE_LOG_PATH; do
        if ! [ $"$v" ]; then
            echo '$'$v' not set.  Run with -f to force.'
            exit -1
        fi
    done
fi

# Prepend this VM's ID to the instance name template to
# facilitate cleanup
vm_id=`/opt/nodepool-scripts/my_vm_id.sh`
sed "s/^instance_name_template =.*/instance_name_template = pvm$vm_id-%(display_name).11s-%(uuid).8s/" \
    /opt/stack/powervm-ci/devstack/$ZUUL_BRANCH/$conf_file > /opt/stack/devstack/local.conf

# Logs setup
mkdir -p /opt/stack/logs

# This list is built from prepare_node_powervm.sh
for proj in ceilometer ceilometer-powervm cinder devstack glance horizon keystone networking-powervm neutron nova nova-powervm requirements; do
    cd /opt/stack/$proj
    git checkout $ZUUL_BRANCH
    git pull
done

# Tempest doesn't follow the same branching scheme, only has a remote master branch
cd /opt/stack/tempest
if [ "$ZUUL_BRANCH" == "master" ] || [ "$ZUUL_BRANCH" == "stable/ocata" ]; then
    git checkout master
    git pull
elif [ "$ZUUL_BRANCH" == "stable/newton" ]; then
    git checkout 13.0.0
else
    echo "$ZUUL_BRANCH is not a supported branch for tempest"
    exit 1
fi

if ! $FORCE || [ "$ZUUL_PROJECT""$BASE_LOG_PATH" ]; then
    # Apply upstream change
    cd /opt/stack/${ZUUL_PROJECT##*/}
    git fetch https://review.openstack.org/$ZUUL_PROJECT refs/changes/$BASE_LOG_PATH
    git checkout FETCH_HEAD
fi

if [ "$ZUUL_BRANCH" == "master" ]; then
    OPENSTACK_REPO="https://review.openstack.org/openstack/nova"
    cd /opt/stack/nova
    for i in $(echo $nova_patch_list | sed "s/,/ /g"); do
        patch=`get_latest_patch "$OPENSTACK_REPO" "$i"`
        refspec=${patch#*|}
        commit=${patch%|*}
        # Only apply the patch if it's not in the chain of the change set we're testing.
        if git log --pretty=format:%H {{ nova_chain_base_commit }}..HEAD | grep -q $commit; then
            echo "Skipping nova commit $commit of change $i because it's already in the commit chain."
        else
            echo "Applying nova ref $refspec of change set $i (commit $commit)"
            git fetch "$OPENSTACK_REPO" $refspec
            git cherry-pick --keep-redundant-commits FETCH_HEAD
        fi
    done
fi

pypowervm_version=$(awk -F= '$1=="pypowervm" {print $NF}' /opt/stack/requirements/upper-constraints.txt)

# If running on newton or ocata the session config patch needs to be applied.
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

# Setuptools has an open issue https://github.com/pypa/pip/issues/4264
# Until that issue is resolved, downgrading appdirs and pyparsing during
# the tempest install causes stacking to fail. Removing these from u-c
# until the issue is resolved.
sudo sed -i '/appdirs/d' /opt/stack/requirements/upper-constraints.txt
sudo sed -i '/pyparsing/d' /opt/stack/requirements/upper-constraints.txt

# TODO: Figure out why devstack can't create/access these
sudo mkdir /etc/neutron/
sudo chown jenkins:jenkins /etc/neutron
mkdir /etc/neutron/plugins/
mkdir /etc/neutron/plugins/ml2

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

if [ "$ZUUL_BRANCH" != "stable/ocata" ] && [ "$ZUUL_BRANCH" != "stable/newton" ]; then
    # Set /etc/environment as the environment file location for the systemd services.
    # This is needed for remote pypowervm. It uses the environment var
    # PYPOWERVM_SESSION_CONFIG, which we set in /etc/environment. The services need
    # to be reloaded and restarted for the change to take effect.
    pvm_services="pvm-q-sea-agt pvm-q-sriov-agt n-cpu pvm-ceilometer-acompute"
    for service in $pvm_services; do
        if [[ -f /etc/systemd/system/devstack@$service.service ]]; then
            sudo sed -i '/^\[Service\]$/a\EnvironmentFile=-/etc/environment' /etc/systemd/system/devstack@$service.service
        fi
    done
    sudo systemctl daemon-reload
    for service in $pvm_services; do
        if [[ -f /etc/systemd/system/devstack@$service.service ]]; then
            sudo systemctl restart devstack@$service.service
        fi
    done

    # Discover the hosts and add them to the default cell. --strict ensures that
    # a host is found and mapped before moving on.
    count=0
    until nova-manage cell_v2 discover_hosts --strict; do
        if [ "$count" -gt "60" ]; then
            echo "Unable to discover any hosts within 60 seconds. Exiting"
            exit 1
        fi
        sleep 5;
        count=$(( count + 5 ))
    done
fi

# Create public and private networks for the tempest runs
if ! $in_tree; then
    source /opt/stack/devstack/openrc admin admin
    if [ "$ZUUL_BRANCH" == "master" ]; then
        #TODO: Devstack isn't respecting NEUTRON_CREATE_INITIAL_NETWORKS=False.
        # Deleting the created private network for now. Further investigation needed.
        # This became necessary after moving away from neutron legacy
        # https://github.com/powervm/powervm-ci/commit/7808f63
        neutron net-delete private
    fi
    neutron net-create public --provider:physical_network default --provider:network_type vlan --shared
    neutron subnet-create --disable-dhcp --name public_subnet --gateway 192.168.2.254 --allocation-pool start=192.168.2.10,end=192.168.2.200 public 192.168.2.0/24
    neutron net-create private --provider:physical_network default --provider:network_type vlan --shared
    neutron subnet-create --disable-dhcp --name private_subnet --gateway 192.168.3.254 --allocation-pool start=192.168.3.10,end=192.168.3.200 private 192.168.3.0/24
fi

exit 0
