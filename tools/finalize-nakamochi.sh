#!/usr/bin/env bash
# shellcheck disable=SC2064

if [[ -z $2 ]]; then
    echo "Usage: $(basename "$0") /dev/sdA2 /dev/sdB1 [/mnt/usd [/mnt/ssd]]"
    echo "Where:"
    echo "  /dev/sdA2   - uSD card root partition"
    echo "  /dev/sdB1   - SSD data partition"
    echo "  /mnt/usd    - uSD card mount point"
    echo "  /mnt/ssd    - SSD mount point"
    echo "Example: $(basename "$0") /dev/sdc2 /dev/sdd1"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (hint: use sudo)."
    exit 1
fi

check_exists()
{
    command -v "$1" > /dev/null
}

if ! check_exists mkp224o; then
    echo "Error: mkp224o is not installed."
    exit 1
fi

USD_DEVICE="$1"
SSD_DEVICE="$2"
USD_MOUNT_POINT="${3:-/mnt/usd}"
SSD_MOUNT_POINT="${4:-/mnt/ssd}"

if [[ ! -b "$USD_DEVICE" ]]; then
    echo "Error: $USD_DEVICE does not exist."
    exit 1
fi

if [[ ! -b "$SSD_DEVICE" ]]; then
    echo "Error: $SSD_DEVICE does not exist."
    exit 1
fi

if [[ ! -d "$USD_MOUNT_POINT" ]]; then
    echo "Creating mount point: $USD_MOUNT_POINT ..."
    mkdir -p "$USD_MOUNT_POINT" || exit 1
    echo "done."
fi

if [[ ! -d "$SSD_MOUNT_POINT" ]]; then
    echo "Creating mount point: $SSD_MOUNT_POINT ..."
    mkdir -p "$SSD_MOUNT_POINT" || exit 1
    echo "done."
fi

echo -n "Mounting $USD_DEVICE to $USD_MOUNT_POINT ... "
mount "$USD_DEVICE" "$USD_MOUNT_POINT" || exit 1
echo "done."

echo "Mounting $SSD_DEVICE to $SSD_MOUNT_POINT ..."
mount "$SSD_DEVICE" "$SSD_MOUNT_POINT" || exit 1
echo "done."

# be sure to always umount, even if user presses Ctrl+C.
# two traps are needed to guard against executing commands twice.
trap "umount -l $USD_MOUNT_POINT ; umount -l $SSD_MOUNT_POINT" EXIT
trap "exit 1" SIGINT SIGTERM

# check SSD
if [[ ! -d "$SSD_MOUNT_POINT"/tor/bitcoind ]]; then
    echo "Error: $SSD_MOUNT_POINT/tor/bitcoind does not exist, is not a correctly prepared SSD."
    exit 1
fi

# reduce reserved space on the SSD
tune2fs -r 1000000 "$SSD_DEVICE"

# generate 2 onion services, one for bitcoind and one for lnd
echo -n "Generating onion services ... "
onion_tmp_dir="$(mktemp -d)"
mkp224o -d "$onion_tmp_dir" -n 1 b
mkp224o -d "$onion_tmp_dir" -n 1 l
echo "done."

# copy the generated service directories to the SSD and fix user/group
echo -n "Configuring onion services ... "
cp -r "$onion_tmp_dir"/b* "$SSD_MOUNT_POINT"/tor/bitcoind
cp -r "$onion_tmp_dir"/l* "$SSD_MOUNT_POINT"/tor/lnd
onion_user_group="$(grep tor "$USD_MOUNT_POINT"/etc/passwd | cut -d: -f 3-4)"
chown -R "$onion_user_group" "$SSD_MOUNT_POINT"/tor
echo "done."

# generate a bitcoin RPC auth
rpcauth="$(python3 "$(dirname "$0")/rpcauth.py" rpc | grep rpcauth=)"
if [[ -z $rpcauth ]]; then
    echo "Error: failed to generate bitcoin RPC auth."
    exit 1
fi

# modify bitcoin configuration
echo -n "Finalizing bitcoin configuration ..."
bitcoind_onion_hostname="$(cat "$SSD_MOUNT_POINT"/tor/bitcoind/hostname)"
sed -i "s/^rpcauth=.*/$rpcauth/" "$USD_MOUNT_POINT"/home/bitcoind/mainnet.conf
sed -i "s/\${hostname.onion}/$bitcoind_onion_hostname/g" "$USD_MOUNT_POINT"/home/bitcoind/mainnet.conf
echo "done."

# modify lnd configuration
echo -n "Finalizing lnd configuration ..."
lnd_onion_hostname="$(cat "$SSD_MOUNT_POINT"/tor/lnd/hostname)"
sed -i "s/\${hostname.onion}/$lnd_onion_hostname/g" "$USD_MOUNT_POINT"/home/lnd/lnd.mainnet.conf
echo "done."

# fix bitcoin and lnd user/group on SSD to match uSD (just in case)
echo -n "Checking / fixing bitcoin and lnd user/group on SSD ... "
bitcoind_user_group="$(grep bitcoind "$USD_MOUNT_POINT"/etc/passwd | cut -d: -f 3-4)"
chown -R "$bitcoind_user_group" "$SSD_MOUNT_POINT"/bitcoind
lnd_user_group="$(grep lnd "$USD_MOUNT_POINT"/etc/passwd | cut -d: -f 3-4)"
chown -R "$lnd_user_group" "$SSD_MOUNT_POINT"/lnd
echo "done."

sync
echo "All DONE, Nakamochi uSD and SSD should be ready!"
