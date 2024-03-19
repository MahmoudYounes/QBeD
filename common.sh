#!/bin/bash

bail() { echo "FATAL: $1"; exit 1;}

bail_if_not_root(){
    if [[ $(whoami) != "root" ]]; then
        bail "script must be excuted as root"
    fi
}
