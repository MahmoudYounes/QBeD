#!/bin/bash

# bails with exit 1
bail() { echo "FATAL: $1"; exit 1;}

# if not root then bail
bail_if_not_root(){
    if [[ $(whoami) != "root" ]]; then
        bail "script must be excuted as root"
    fi
}

# checks if mounts required by QBeD are mounted
bail_if_not_vfs_mounted(){
    bail_if_not_root

    is_vfs_target_mounted $LFS/dev/pts
    is_vfs_target_mounted $LFS/dev/shm
    is_vfs_target_mounted $LFS/proc
    is_vfs_target_mounted $LFS/sys
    is_vfs_target_mounted $LFS/run
}

# given a target that is known to be VFS (method will not check the type or permissions, etc)
is_vfs_target_mounted(){
    if [ $# != 1 ]; then
        bail "expected one path to check"
    fi

    bail_if_not_root

    out=$(findmnt -t devpts,udev,tmpfs,proc,sysfs -T $1 --noheading --output TARGET)
    if [ $? != 0 ]; then
        bail "error while checking if $1 is mounted"
    fi

    if [[ $out != $1 ]]; then
        bail "$1 is not mounted"
    fi
}

# creates a backup of QBeD system
backup_lfs(){
    if [ $(whoami) != "root" ]; then
        bail "must backup as root"
    fi

    cd $LFS
    tar -cJpf $HOME/lfs-temp-tools-d7cb883f5f4bdb5497baa2562652c11f2d805ac7-systemd.tar.xz .
}

# restore the backup of QBeD
restore_lfs(){
    if [ $(whoami) != "root" ]; then
        bail "must restore as root"
    fi

    cd $LFS
    rm -rf ./*
    tar -xpf $HOME/lfs-temp-tools-d7cb883f5f4bdb5497baa2562652c11f2d805ac7-systemd+.tar.xz
}

# mounts the VFS required for QBeD
mount_vfs(){
    bail_if_not_root
    if [ -z $LFS ]; then export LFS=/mnt/qbed;fi

    chown -R root:root $LFS/{usr,lib,var,etc,bin,sbin}

    if [ -d $LFS/tools ]; then
        chown -R root:root $LFS/tools
    fi

    case $(uname -m) in
        x86_64)
            chown -R root:root $LFS/lib64
            ;;
    esac

    mkdir -pv $LFS/{dev,proc,sys,run}

    # bind mounting /dev devtmpfs
    mount -v --bind /dev $LFS/dev

    # bind mount pesudo terminal vfs
    mount -v --bind /dev/pts $LFS/dev/pts

    # mount procfs
    mount -vt proc proc $LFS/proc

    # mount sysfs
    mount -vt sysfs sysfs $LFS/sys

    # mount tmpfs
    mount -vt tmpfs tmpfs $LFS/run

    if [ -h $LFS/dev/shm ]; then
        mkdir -pv $LFS/$(readlink $LFS/dev/shm)
    else
        mount -t tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
    fi

    if [ ! -a $LFS/lib/ld-linux-x86-64.so.2 ]; then
        cp $LFS/sources/glibc-2.37/build/elf/ld-linux-x86-64.so.2 $LFS/lib/
    fi
}

# unmounts the VFS mounted for QBeD
umount_vfs(){
    bail_if_not_root

    # unmount vfs
    mountpoint -q $LFS/dev/shm && umount $LFS/dev/shm
    mountpoint -q $LFS/dev/pts && umount $LFS/dev/pts
    mountpoint -q $LFS/sys && umount $LFS/sys
    mountpoint -q $LFS/proc && umount $LFS/proc
    mountpoint -q $LFS/run && umount $LFS/run
    mountpoint -q $LFS/dev && umount $LFS/dev
}

# enters the chroot env
enter_chroot(){
    bail_if_not_root

    mount_vfs
    bail_if_not_vfs_mounted

    chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PS1='(lfs chroot) \u:\w\$ ' PATH=/usr/bin:/usr/sbin /bin/bash --login
}
