#!/usr/bin/env bash
# shellcheck disable=SC2064

check_exists()
{
    command -v "$1" > /dev/null
}

patch_bitcoind_conf()
{
    bitcoind_conf="$1"
    rpcauth="$2"
    bitcoind_rpcpass="$3"
    bitcoind_onion_hostname="$4"
    # commented out RPC password after "# rpcauth.py rpc" line is currently
    # needed for ndg when modifying LND configuration on the fly.
    # https://github.com/nakamochi/ndg/blob/538ecd957c3f989485b0f8f6982c9cd1817dc56b/src/nd/Config.zig#L155-L158
    sed -i "/# rpcauth.py rpc/{n;s/.*/# $bitcoind_rpcpass/}" "$bitcoind_conf"
    sed -i "s/^rpcauth=.*/$rpcauth/" "$bitcoind_conf"
    sed -i "s/^externalip=.*/externalip=$bitcoind_onion_hostname/" "$bitcoind_conf"
}

patch_lnd_conf()
{
    lnd_conf="$1"
    bitcoind_rpcuser="$2"
    bitcoind_rpcpass="$3"
    lnd_onion_hostname="$4"
    sed -i "s/^bitcoind.rpcuser=.*/bitcoind.rpcuser=$bitcoind_rpcuser/" "$lnd_conf"
    sed -i "s/^bitcoind.rpcpass=.*/bitcoind.rpcpass=$bitcoind_rpcpass/" "$lnd_conf"
    sed -i "s/^tlsextradomain=.*/tlsextradomain=$lnd_onion_hostname/" "$lnd_conf"
    sed -i "s/^externalhosts=.*/externalhosts=$lnd_onion_hostname/" "$lnd_conf"
}

run_main()
{
    if [[ -z $2 ]] || [[ "$1" == "--help" ]]; then
        echo "Usage: $(basename "$0") [options] /dev/sda2 /dev/sdb1 [/mnt/usd [/mnt/ssd]]"
        echo "Where:"
        echo "  /dev/sda2       - uSD card root partition (use '-' to not mount)"
        echo "  /dev/sdb1       - SSD data partition (use '-' to not mount)"
        echo "  /mnt/usd        - uSD card mount point / directory"
        echo "  /mnt/ssd        - SSD mount point / directory"
        echo "Options:"
        echo "  --skip-mkp224o  - skip generating onion keys (requires them to be already present on SSD)"
        echo "  --test-image    - configure image for testing (allows ssh root access with password)"
        # FixMe: --update-update is temporary hack, remove after https://github.com/nakamochi/sysupdates/pull/8 is merged.
        echo "  --update-update - update /sysupdates/update.sh on SSD from local copy"
        echo "Example: $(basename "$0") /dev/sdc2 /dev/sdd1"
        exit 1
    fi

    if [[ -z $NOSUDOTESTMODE ]] && [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (hint: use sudo)."
        exit 1
    fi

    skip_mkp224o=0
    test_image=0
    update_update=0
    while [[ "$1" == --* ]]; do
        case "$1" in
            --skip-mkp224o)
                skip_mkp224o=1
                shift
                ;;
            --test-image)
                test_image=1
                shift
                ;;
            --update-update)
                update_update=1
                shift
                ;;
            *)
                echo "Error: unknown option $1"
                exit 1
                ;;
        esac
    done

    if [[ "$skip_mkp224o" -eq 0 ]]; then
        if ! check_exists mkp224o; then
            echo "Error: mkp224o is not installed."
            exit 1
        fi
    fi

    if ! check_exists mkpasswd; then
        echo "Error: mkpasswd not found, try 'apt install whois'."
        exit 1
    fi

    if [[ ! -x "$(dirname "$0")/rpcauth.py" ]]; then
        echo "Error: rpcauth.py not found or is not executable."
        exit 1
    fi

    USD_DEVICE="$1"
    SSD_DEVICE="$2"
    USD_MOUNT_POINT="${3:-/mnt/usd}"
    SSD_MOUNT_POINT="${4:-/mnt/ssd}"

    # "-" is a special case for tests without automounting.

    if [[ "$USD_DEVICE" != "-" ]] && [[ ! -b "$USD_DEVICE" ]]; then
        echo "Error: device $USD_DEVICE does not exist."
        exit 1
    fi

    if [[ "$SSD_DEVICE" != "-" ]] && [[ ! -b "$SSD_DEVICE" ]]; then
        echo "Error: device $SSD_DEVICE does not exist."
        exit 1
    fi

    if [[ ! -d "$USD_MOUNT_POINT" ]]; then
        if [[ "$USD_DEVICE" != "-" ]]; then
            echo -n "Creating mount point: $USD_MOUNT_POINT ... "
            mkdir -p "$USD_MOUNT_POINT" || exit 1
            echo "done."
        else
            echo "Error: directory $USD_MOUNT_POINT does not exist."
            exit 1
        fi
    fi

    if [[ ! -d "$SSD_MOUNT_POINT" ]]; then
        if [[ "$SSD_DEVICE" != "-" ]]; then
            echo -n "Creating mount point: $SSD_MOUNT_POINT ... "
            mkdir -p "$SSD_MOUNT_POINT" || exit 1
            echo "done."
        else
            echo "Error: directory $SSD_MOUNT_POINT does not exist."
            exit 1
        fi
    fi

    if [[ "$USD_DEVICE" != "-" ]]; then
        echo -n "Mounting $USD_DEVICE to $USD_MOUNT_POINT ... "
        mount "$USD_DEVICE" "$USD_MOUNT_POINT" || exit 1
        echo "done."
    else
        echo "Using $USD_MOUNT_POINT directory as a uSD card."
    fi

    if [[ "$SSD_DEVICE" != "-" ]]; then
        echo -n "Mounting $SSD_DEVICE to $SSD_MOUNT_POINT ... "
        mount "$SSD_DEVICE" "$SSD_MOUNT_POINT" || exit 1
        echo "done."
    else
        echo "Using $SSD_MOUNT_POINT directory as a SSD."
    fi

    if [[ "$USD_DEVICE" != "-" ]] || [[ "$SSD_DEVICE" != "-" ]]; then
        # be sure to always umount, even if user presses Ctrl+C.
        # two traps are needed to guard against executing commands twice.
        trap "umount -l $USD_MOUNT_POINT ; umount -l $SSD_MOUNT_POINT" EXIT
        trap "exit 1" SIGINT SIGTERM
    fi

    # check SSD
    if [[ ! -d "$SSD_MOUNT_POINT"/bitcoind/mainnet/blocks ]]; then
        echo "Error: $SSD_MOUNT_POINT/bitcoind/mainnet/blocks does not exist, is not a correctly prepared SSD."
        exit 1
    fi

    if [[ "$skip_mkp224o" -eq 1 ]]; then
        # check for existing onion keys
        if [[ ! -f "$SSD_MOUNT_POINT"/tor/bitcoind/hostname ]]; then
            echo "Error: $SSD_MOUNT_POINT/tor/bitcoind/hostname does not exist, cannot --skip-mkp224o."
            exit 1
        fi
        if [[ ! -f "$SSD_MOUNT_POINT"/tor/lnd/hostname ]]; then
            echo "Error: $SSD_MOUNT_POINT/tor/lnd/hostname does not exist, cannot --skip-mkp224o."
            exit 1
        fi
    fi

    # check for existing lightning wallet
    if [[ -f "$SSD_MOUNT_POINT/lnd/data/chain/bitcoin/mainnet/wallet.db" ]]; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "Existing lightning wallet found on SSD."
        read -r -n 1 -p "Are you sure to remove it and proceed? (y/n) "
        echo ""
        if [[ ${REPLY} =~ y|Y ]]; then
            echo -n "Clearing contents of $SSD_MOUNT_POINT/lnd/ ... "
            rm -rf "$SSD_MOUNT_POINT"/lnd/*
            echo "done."
            echo -n "Removing wallet unlock file and clearing LND config ... "
            rm -f "$USD_MOUNT_POINT"/home/lnd/walletunlock.txt
            sed -i "s/^wallet-unlock-password-file=.*/;wallet-unlock-password-file=\/home\/lnd\/walletunlock.txt/" "$USD_MOUNT_POINT"/home/lnd/lnd.mainnet.conf
            echo "done."
        else
            echo "Aborted."
            exit 1
        fi
    fi

    if [[ "$SSD_DEVICE" != "-" ]]; then
        # reduce reserved space on the SSD
        tune2fs -r 1000000 "$SSD_DEVICE"
    fi

    # generate and write same UUID on both uSD card and SSD so that it can be
    # detected that mismatched uSD and SSD are used on the same Nakamochi.
    NAKAMOCHI_ID="$(uuidgen)"
    echo "Nakamochi ID: $NAKAMOCHI_ID"
    echo "$NAKAMOCHI_ID" > "$USD_MOUNT_POINT"/etc/nakamochi-id
    echo "$NAKAMOCHI_ID" > "$SSD_MOUNT_POINT"/nakamochi-id

    if [[ "$skip_mkp224o" -eq 0 ]]; then
        # generate 2 onion services, one for bitcoind and one for lnd
        echo -n "Generating onion services ... "
        onion_tmp_dir="$(mktemp -d)"
        mkp224o -d "$onion_tmp_dir" -n 1 b
        mkp224o -d "$onion_tmp_dir" -n 1 l
        echo "done."
    fi

    # copy the generated service directories to the SSD and fix user/group
    echo -n "Configuring onion services ... "
    if [[ "$skip_mkp224o" -eq 0 ]]; then
        mkdir -p "$SSD_MOUNT_POINT"/tor/{bitcoind,lnd}
        cp -r "$onion_tmp_dir"/b*/* "$SSD_MOUNT_POINT"/tor/bitcoind/
        cp -r "$onion_tmp_dir"/l*/* "$SSD_MOUNT_POINT"/tor/lnd/
    fi
    onion_user_group="$(grep tor "$USD_MOUNT_POINT"/etc/passwd | cut -d: -f 3-4)"
    chown -R "$onion_user_group" "$SSD_MOUNT_POINT"/tor
    echo "done."

    # generate a bitcoin RPC auth
    echo -n "Generating bitcoin RPC auth ... "
    bitcoind_rpcuser="rpc"
    rpcauth_out="$(python3 "$(dirname "$0")/rpcauth.py" $bitcoind_rpcuser)"
    if [[ -z $rpcauth_out ]]; then
        echo ""
        echo "Error: failed to generate bitcoin RPC auth."
        exit 1
    fi
    bitcoind_rpcauth="$(grep "rpcauth=" <<< "$rpcauth_out")"
    bitcoind_rpcpass="$(tail -n 1 <<< "$rpcauth_out")"
    echo "done."

    # modify bitcoin configuration
    bitcoind_conf="$USD_MOUNT_POINT"/home/bitcoind/mainnet.conf
    echo -n "Finalizing bitcoin configuration ($bitcoind_conf) ..."
    bitcoind_onion_hostname="$(cat "$SSD_MOUNT_POINT"/tor/bitcoind/hostname)"
    patch_bitcoind_conf "$bitcoind_conf" "$bitcoind_rpcauth" "$bitcoind_rpcpass" "$bitcoind_onion_hostname"
    echo "done."
    grep rpc "$bitcoind_conf"

    # modify lnd configuration
    lnd_conf="$USD_MOUNT_POINT"/home/lnd/lnd.mainnet.conf
    echo -n "Finalizing lnd configuration ($lnd_conf) ..."
    lnd_onion_hostname="$(cat "$SSD_MOUNT_POINT"/tor/lnd/hostname)"
    patch_lnd_conf "$lnd_conf" "$bitcoind_rpcuser" "$bitcoind_rpcpass" "$lnd_onion_hostname"
    echo "done."
    grep rpc "$lnd_conf"

    # fix bitcoin and lnd user/group on SSD to match uSD (just in case)
    echo -n "Checking / fixing bitcoin and lnd user/group on SSD ... "
    bitcoind_user_group="$(grep bitcoind "$USD_MOUNT_POINT"/etc/passwd | cut -d: -f 3-4)"
    chown -R "$bitcoind_user_group" "$SSD_MOUNT_POINT"/bitcoind
    lnd_user_group="$(grep lnd "$USD_MOUNT_POINT"/etc/passwd | cut -d: -f 3-4)"
    chown -R "$lnd_user_group" "$SSD_MOUNT_POINT"/lnd
    echo "done."

    # finalize image for testing or production
    if [[ "$test_image" -eq 1 ]]; then
        echo -n "Finalizing image for testing ... "
        sed -i "s/^#?PermitRootLogin.*/PermitRootLogin yes/" "$USD_MOUNT_POINT"/etc/ssh/sshd_config
        sed -i "s/^#?PasswordAuthentication.*/PasswordAuthentication yes/" "$USD_MOUNT_POINT"/etc/ssh/sshd_config
        root_pass="nakamochi"
        crypted_root_pass="$(mkpasswd "$root_pass" | sed 's/\$/\\\$/g')"
        sed -i "s|^root:[^:]*:|root:$crypted_root_pass:|" "$USD_MOUNT_POINT"/etc/shadow
        echo "done."
        echo "Test image root password is $root_pass, ssh root login allowed."
    else
        echo -n "Finalizing image for production ... "
        sed -i "s/^#?PermitRootLogin.*/PermitRootLogin no/" "$USD_MOUNT_POINT"/etc/ssh/sshd_config
        sed -i "s/^#?PasswordAuthentication.*/PasswordAuthentication no/" "$USD_MOUNT_POINT"/etc/ssh/sshd_config
        crypted_root_pass="$(mkpasswd "$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 13; echo)" | sed 's/\$/\\\$/g')"
        sed -i "s|^root:[^:]*:|root:$crypted_root_pass:|" "$USD_MOUNT_POINT"/etc/shadow
        echo "done."
    fi

    if [[ "$update_update" -eq 1 ]]; then
        # update /sysupdates/update.sh on SSD from local copy
        echo -n "Updating /sysupdates/update.sh on SSD ... "
        cp "$(dirname "$0")/update.sh" "$SSD_MOUNT_POINT"/sysupdates/update.sh
        chmod +x "$SSD_MOUNT_POINT"/sysupdates/update.sh
        echo "done."
    fi

    # clear logs, shell history, ssh keys and networks
    echo -n "Clearing logs, shell history, ssh keys and networks ... "
    rm -f "$USD_MOUNT_POINT"/var/log/* 2> /dev/null
    for d in "$USD_MOUNT_POINT"/var/log/socklog/*; do echo > "$d/current"; done
    rm "$USD_MOUNT_POINT"/root/.bash_history
    echo > "$USD_MOUNT_POINT"/root/.ssh/authorized_keys
    cp "$(dirname "$0")"/../rootfiles/etc/wpa_supplicant/wpa_supplicant.conf "$USD_MOUNT_POINT"/etc/wpa_supplicant/wpa_supplicant.conf
    echo "done."

    sync
    echo "All DONE, Nakamochi uSD and SSD should be ready!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_main "$@"
fi
