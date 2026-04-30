#!/usr/bin/env bash

run_main() {
    if [[ -z $2 ]] || [[ "$1" == "--help" ]]; then
        echo "Usage: $(basename "$0") image device"
        echo "Example: $(basename "$0") /path/to/image.img /dev/sdc"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root."
        exit 1
    fi

    image="$1"
    device="$2"
    if [[ ! -f "$image" ]]; then
        echo "Error: Image file '$image' does not exist."
        exit 1
    fi
    if [[ ! -b "$device" ]]; then
        echo "Error: Device '$device' does not exist."
        exit 1
    fi
    # unmount any mounted partitions of the target device
    while read -r part mnt; do
        echo -n "Unmounting $part from $mnt... "
        umount "$part"
	echo "done."
    done < <(lsblk -nrpo NAME,MOUNTPOINT "$device" | awk '$2 != "" && $1 != dev { print $1, $2 }' dev="$device")
    echo "Flashing $image to $device..."
    dd if="$image" of="$device" bs=4M status=progress
    sync
    echo "Flashing completed."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_main "$@"
fi

