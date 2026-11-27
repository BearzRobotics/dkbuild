#!/bin/sh

# A list of devices to mount. These must have a mount point specified in
# /etc/fstab (and should be set "noauto" to prevent earlier mounting).
LATE_FILESYSTEMS=""

RESULT=0

if [ "$1" = start ]; then

    PATH=/usr/bin:/usr/sbin:/bin:/sbin
    
    if [ ! -z "$LATE_FILESYSTEMS" ]; then
        for FS in $LATE_FILESYSTEMS; do
            # already mounted (FS is a device or a mount point): not checked, and not mounted a second time
            if findmnt -rn "$FS" >/dev/null; then
                echo "$FS is already mounted"
                continue
            fi
            fsck -M -a "$FS"
            fsckresult=$?
            if [ $(( $fsckresult & ~(1 + 32) )) -eq 0 ]; then
                mount --onlyonce "$FS"
                mntresult=$?
                if [ $mntresult -ne 0 ]; then
                    RESULT=$mntresult
                fi
            else
                RESULT=$fsckresult
            fi
        done
    fi

fi

exit $RESULT
