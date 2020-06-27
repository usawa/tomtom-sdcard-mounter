#!/usr/bin/env bash

typeset -i MAX_FILES
MAX_FILES=8

# Output to stderr
function echoerr() { 
    echo "$@" 1>&2; 
}

# Find first available /dev/loopX
function loopback_dev() {
    typeset -i num
    num=0
    while [[ ${num} -le 255 ]]
    do
        losetup /dev/loop${num} >/dev/null 2>&1 
        [[ $? -ne 0 ]] && break
        num=num+1
    done

    echo "/dev/loop${num}"
}

# Count the number of TOMTOM.xxx files
function count_tomtom_vfs_files() {
    typeset -i count_vfs_files
    count_vfs_files=0

    TOMTOM_PATH=$1

    while [[ -e ${TOMTOM_PATH}/TOMTOM.$(printf "%03d" ${count_vfs_files}) ]]
    do
        count_vfs_files+=1
    done

    echo ${count_vfs_files}
    
}

# Associate all TOMTOM.xxx files to a loopback device
function init_loopback_devs() {
    typeset -gi COUNT_VFS_FILES
    TOMTOM_PATH=$1
    LOOPBACK_DEV_LIST=""

    COUNT_VFS_FILES=$(count_tomtom_vfs_files ${TOMTOM_PATH})
    echo "${COUNT_VFS_FILES} tomtom files found."

    echo "Creating loopback devices."

    for ((i=0;i<${COUNT_VFS_FILES};i++))
    do
        VFS_FILE=${TOMTOM_PATH}/TOMTOM.$(printf "%03d" $i)
        LOOPBACK_DEV=$(loopback_dev)
        LOOPBACK_DEV_LIST="${LOOPBACK_DEV_LIST} ${LOOPBACK_DEV}"

        # associate file to loopback device
        sudo losetup ${LOOPBACK_DEV} ${VFS_FILE}
        if [[ $? -ne 0 ]]
        then
            echoerr "Error while creating loopback device ${LOOPBACK_DEV} from ${VFS_FILE}. Cancel."
            remove_loopback_devs
            exit 1
        fi
        
        echo "${VFS_FILE} is now associated to ${LOOPBACK_DEV}."
    done
}

# Delete all loopback devices
function remove_loopback_devs() {
    echo "Removing all loopback devices."
    sudo losetup -d ${LOOPBACK_DEV_LIST}
    if [[ $? -ne 0 ]]
    then
        echoerr "Error while removing one or multiple loopback devices. Please check with losetp and dmesg."
        exit 1
    fi

    return 0
}

# Build the linear raid device from all loopback devices (TOMTOM.xxx files)
function build_linear_raid() {
    echo "Build linear raid device."
    COMMAND="mdadm --build --auto=part --verbose /dev/md/tomtom_vfs --rounding=32 --level=linear -n${COUNT_VFS_FILES} ${LOOPBACK_DEV_LIST}"
    sudo $COMMAND
    if [[ $1 -ne 0 ]]
    then
        echoerr "Error during raid device creation. Trying to cancel. Check /proc/mdstat, mdadm and dmesg."
        remove_loopback_devs
        exit 1
    fi
    return 0
}

# Delete the /dev/md/tomtom_vfs raid device
function delete_linear_raid() {
    echo "Stopping linear raid device."
    sudo mdadm -S /dev/md/tomtom_vfs
    if [[ $1 -ne 0 ]]
    then
        echoerr "Error during raid device deletion. Please check /proc/mdstat, mdadm and dmesg. Loopback devices won't be removed."
        exit 1
    fi
    return 0
}

# wait for a carriage return
function wait_for_return() {
    echo "Please press return to finish :"
    read dummy
    echo "Thank you."
    return 0
}

# Mount the TOMTOM.xxx linear raid ex3 filesystem in /mnt/tomtom_vfs
function mount_vfs() {

    # Ensure it's not already mounted
    mount | grep "on /mnt/tomtom_vfs " >/dev/null 2>&1
    if [[ $? -eq 0 ]]
    then
        echo "Mountpoint already in use. Cancel."
    else
        echo "Creating mount point and mount tomtom filesystem."
        sudo mkdir -p /mnt/tomtom_vfs 2>/dev/null
        sudo mount /dev/md/tomtom_vfs /mnt/tomtom_vfs
        if [[ $? -eq 0 ]]
        then 
            vfs_user=$(stat -c "%u" /mnt/tomtom_vfs/common)
            vfs_group=$(stat -c "%g" /mnt/tomtom_vfs/common)
            current_group=$(id -gn)

            # bind to 
            mkdir -p $HOME/tomtom_vfs
            sudo bindfs -u $USER -g ${current_group} --create-for-user=${vfs_user} --create-for-group=${vfs_group} /mnt/tomtom_vfs/ $HOME/tomtom_vfs
            echo "Filesystem is now available in /mnt/tomtom_vfs as root and $HOME/tomtom_vfs as $USER"
            sleep 1
        else
            echoerr "Something is wrong. Corrupted files ? Trying to cancel."
            umount_vfs
            delete_linear_raid
            remove_loopback_devs
            exit 1
        fi     
    fi
    return 0
}

# unmount /mnt/tomtom_vfs (TOMTOM.xxx linear raid ext3 filesystem)
function umount_vfs() {
    # Ensure it's mounted
    mount | grep "on /mnt/tomtom_vfs " >/dev/null 2>&1
    if [[ $? -ne 0 ]]
    then
        echo "Nothing to do, /mnt/tomtom_vfs Not mounted."
        return 0
    fi

    # synchronise files
    sync

    # check if there's something to kill
    fuserkill=0
    lsof /$HOME/tomtom_vfs >/dev/null 2>&1
    [[ $? -ne 1 ]] && fuserkill=1
    lsof /mnt/tomtom_vfs >/dev/null 2>&1
    [[ $? -ne 1 ]] && fuserkill=1

    if [[ ${fuserkill} -eq 1 ]]
    then
        # Killing local users
        echo "Killing remaining processus using the mountpoints."
        sudo fuser -k $HOME/tomtom_vfs

        # First kill everything that is related to the mountpoint
        sudo fuser -k /mnt/tomtom_vfs

        echo "Waiting 5 seconds."
        sleep 5
    fi

    # Then, umount
    echo "Unmounting tomtom filesystem and remove mount point."
    sudo fusermount -u $HOME/tomtom_vfs
    sudo umount /mnt/tomtom_vfs
    if [[ $? -ne 0 ]]
    then
        echoerr "Cannot unmount /mnt/tomtom_vfs. Please check dmesg, fuser and dmesg. raid and loopback devices left untouched."
        exit 1
    fi
    sudo rmdir /mnt/tomtom_vfs
    sudo rmdir $HOME/tomtom_vfs
    return 0
}

# If on X, open default file manager
function open_default_file_manager() {
    if xhost >& /dev/null
    then 
        echo "Display exists. Starting default file manager."
        xdg-open $HOME/tomtom_vfs
    fi
    return 0
}

# Check if prerequires are installed
function check_prerequires() {
    ERR=0
    PREREQUIRES="mdadm losetup bindfs"
    for prerequire in $PREREQUIRES
    do
        which $prerequire >/dev/null 2>&1
        if [[ $? -ne 0 ]]
        then
            echoerr "$prerequire command is missing. Please install it (the method depends of your Linux distribution)."
            ERR=1
        fi
    done
    return $ERR
}

function main() {
    if [[ $# -ne 1 ]]
    then
        echo "$0 <path_of_TOMTOM.xxx_files>"
        return 0
    fi

    if [[ $1 = "--help" ]]
    then
        cat<<EOT
$0 <path_of_TOMTOM.xxx_files>
A tomtom r-link sdcard is made of multiple TOMTOM.xxx (000, 001, ...) files.
These files contain a splitted linux filesystem. The scripts will:
- Attach each file to a virtual block device, called a loopback device : /dev/loopX
- Aggregate all these devices as a big "linear" one: /dev/md/tomtom_vfs, seen a a real disk
- Mount this new device to the /mnt/tomtom_vfs directory.
Once done, you can modify the content, to add, for example, POIs.
EOT
        return 0
    fi

    check_prerequires
    [[ $? -ne 0 ]] && exit 1

    echo "Starting."

    init_loopback_devs $1
    build_linear_raid
    mount_vfs
    open_default_file_manager
    wait_for_return
    umount_vfs
    delete_linear_raid
    remove_loopback_devs

    echo "End."
    return 0
}

main $@