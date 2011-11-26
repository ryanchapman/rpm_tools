#!/bin/bash -
#
# Synchronize the vmware tools repository
#
# Ryan Chapman, ryan@heatery.com
# Sat Nov 26 01:26:17 MST 2011


/home/yum/bin/sync_rpms.rb --repo "http://packages.vmware.com/tools/esx/4.1u1/rhel5/x86_64" \
                           --match 'vmware-open-vm-tools-(common|kmod|nox).*' \
                           --dest "/home/yum/yum_root/5/x86_64" \
                           --verbose

echo
/home/yum/bin/sync_rpms.rb --repo "http://packages.vmware.com/tools/esx/4.1u1/rhel5/i386" \
                           --match 'vmware-open-vm-tools-(common|kmod|nox).*' \
                           --dest "/home/yum/yum_root/5/i386" \
                           --verbose

echo
/home/yum/bin/sync_rpms.rb --repo "http://packages.vmware.com/tools/esx/4.1u1/rhel4/x86_64" \
                           --match 'vmware-open-vm-tools-(common|kmod|nox).*' \
                           --dest "/home/yum/yum_root/4/x86_64" \
                           --verbose

echo
/home/yum/bin/sync_rpms.rb --repo "http://packages.vmware.com/tools/esx/4.1u1/rhel4/i386" \
                           --match 'vmware-open-vm-tools-(common|kmod|nox).*' \
                           --dest "/home/yum/yum_root/4/i386" \
                           --verbose

echo "Done. You probably want to recreate repos now by running ~yum/bin/rebuild_repos.sh"
