#!/bin/bash

bail() { echo "FATAL: $1"; exit 1;}

bail_if_not_root(){
    if [[ $(whoami) != "root" ]]; then
        bail "script must be excuted as root"
    fi
}

backup_lfs(){
    if [ $(whoami) != "root" ]; then
        bail "must backup as root"
    fi

    cd $LFS
    tar -cJpf $HOME/lfs-temp-tools-d7cb883f5f4bdb5497baa2562652c11f2d805ac7-systemd.tar.xz .
}

restore_lfs(){
    if [ $(whoami) != "root" ]; then
        bail "must restore as root"
    fi

    cd $LFS
    rm -rf ./*
    tar -xpf $HOME/lfs-temp-tools-d7cb883f5f4bdb5497baa2562652c11f2d805ac7-systemd+.tar.xz
}
