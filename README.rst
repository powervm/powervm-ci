=================================================
powervm-ci - Third-Party OpenStack CI for PowerVM
=================================================

Overview
--------
This repository contains configuration and tooling used to run and maintain
the third-party continuous integration (CI) system that tests OpenStack with
PowerVM systems.

For an overview of OpenStack CI in general, `see the system-config page. <http://docs.openstack.org/infra/system-config/>`_

For an overview of Third-Party CIs in OpenStack, `see the third party page. <http://docs.openstack.org/infra/system-config/third_party.html>`_

Devstack Configuration
----------------------
The devstack local.conf files and prep_devstack.sh and its configuration can
be found in the powervm-ci/devstack/ directory. The underlying directory
structure is powervm-ci/devstack/<branch>/<powervm_driver>/. Only for branches
later than ocata does there exist configuration for the in-tree and out-of-tree
driver. For ocata and prior, only out-of-tree configuration exists. Under each
of these directories there are two files, local.conf and patching.conf. The
first is used for devstack configuration. The second specifies openstack repos
and a list of patches on repo per line in the format found below.

repo1:change_number1,change_number2,...
repo2:change_number1,...
etc.

ex. openstack/tempest:446464,484848
