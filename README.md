# nakamochi system image

system image is the operating system, typically "flashed" onto a uSD card for a Raspberry Pi.
it is based on [void linux](https://voidlinux.org/).

## manual uSD card image creation

the following assumes a device is fully assembled and able to boot from a uSD card.

get an image from void following instructions in https://docs.voidlinux.org/installation/index.html#downloading-installation-media or directly from https://repo-default.voidlinux.org/live/current/ - the one named after `void-rpi-aarch64-YYYYMMDD.img.xz`. it is ARM 64bit, based on glibc. the musl version won't work due to bitcoind requirements.

once downloaded, mount its root partition:

    xz -d void-rpi-aarch64-xxx.img.xz
    cp void-rpi-aarch64-xxx.img nkm.img
    mount -o loop -o offset=269484032 nkm.img /mnt/img

grab ndg release v0.8.1 from https://github.com/nakamochi/ndg/releases and create its system service:

    cd /mnt/img
    mkdir -p home/uiuser/v0.8.1
    tar -C home/uiuser/v0.8.1 --no-same-owner -xf /path/to/ndg-v0.8.1-aarch64.tar.gz
    mkdir etc/sv/nd
    cp -r repo/rootfiles/etc/sv/nd/* etc/sv/nd/

enable few essential services:

    cd /mnt/img/etc/runit/runsvdir/default
    for s in chronyd dhcpcd sshd wpa_supplicant; do ln -s /etc/sv/$s; done

set a suitable hostname:

    cd /mnt/img
    echo nakamochi > etc/hostname

tweak wpa supplicant settings and add a local WLAN to ssh after first boot, unless the device is connected with a network cable:

    cd /mnt/img
    echo 'passive_scan=1' >> etc/wpa_supplicant/wpa_supplicant.conf
    # temporary set up a WLAN in wpa_supplicant.conf if needed

add an ssh pubkey to be able to login remotely, unless keyboard is attached to the device in which case no remote login is required:

    cd /mnt/img
    mkdir root/.ssh
    cat /path/to/ssh-pubkey > root/.sshd/authorized_keys

unmount the image, "flash" onto a uSD card and boot the device:

    umount /mnt/img
    dd if=nkm.img of=/dev/... bs=1M

### the rest of the commands are executed while in ssh session or logged in from a tty with a keyboard.

fix system date/time (otherwise there will be certificate errrors):

    date -s "2024-12-09" # set this to approx today date
    xbps-install ntp
    sv up ntpd

update the system, reboot if requested and install system logging:

    xbps-install -Su
    xbps-install socklog-void
    ln -s /etc/sv/socklog-unix /var/service/
    ln -s /etc/sv/nanoklogd /var/service/

it is now possible to observe all system messages with:

    svlogtail

set up the SSD:

    fdisk /dev/sda
    # create a new partition spanning the whole disk.
    # format and tune:
    mkfs -t ext4 /dev/sda1
    # reduce reserved space
    tune2fs -r 1000000 /dev/sda1
    # set the block ID matching what's in rootfiles/etc/fstab
    tune2fs /dev/sda1 -U be10af47-a9ab-4942-b61f-f3494c1a4485
    # mount
    echo "/dev/sda1 /ssd ext4 nosuid,nodev,noatime 0 1" >> /etc/fstab
    mkdir /ssd
    mount /ssd

add swap:

    dd if=/dev/zero of=/ssd/swapfile bs=1M count=2048
    chmod 600 /ssd/swapfile
    mkswap /ssd/swapfile
    echo "/ssd/swapfile   none    swap    sw,nofail 0 0" >> /etc/fstab

verify that the whole `/etc/fstab` file matches `rootfiles/etc/fstab` and enable swap:

    swapon -af

set up tor and start it up. on first run, it is expected to create hidden
services for bitcoind and lnd used in the next steps.

    xbps-install -y tor
    scp rootfiles/etc/tor/torrc root@target:/etc/tor/
    chgrp tor /etc/tor/torrc
    mkdir /ssd/tor
    chown tor:tor /ssd/tor
    ln -s /etc/sv/tor /var/service/

set up bitcoin core configuration:

    useradd -r -s /sbin/nologin -m bitcoind
    mkdir -p /ssd/bitcoind/mainnet
    chown -R bitcoind:bitcoind /ssd/bitcoind
    chmod -R 750 /home/bitcoind /ssd/bitcoind
    # copy bitcoind config file
    scp rootfiles/home/bitcoind/mainnet.conf root@target:/home/bitcoind/
    chmod 640 /home/bitcoind/mainnet.conf
    chgrp bitcoind /home/bitcoind/mainnet.conf

set up lnd lightning configuration:

    useradd -r -s /sbin/nologin -m lnd
    mkdir /ssd/lnd
    chown -R lnd:lnd /ssd/lnd
    chmod -R 750 /home/lnd /ssd/lnd
    # copy lnd config file
    scp rootfiles/home/lnd/lnd.mainnet.conf root@target:/home/lnd/
    chmod 640 /home/lnd/lnd.mainnet.conf
    chgrp lnd /home/lnd/lnd.mainnet.conf

generate bitcoind RPC auth credentials:

    python3 tools/rpcauth.py rpc

replace `${rpcauth}` with the generated password and `${rpcauth_hash}` with
the hashed value in `/home/bitcoind/mainnet.conf`.

replace `${rpcauth}` with the generated password and `${hostname.onion}` with
`cat /ssd/tor/lnd/hostname` in `/home/lnd/lnd.mainnet.conf`.

add ndg UI user and enable its service:

    useradd -d /home/uiuser -M -c 'nakamochi ui' -s /sbin/nologin uiuser
    ln -s /etc/sv/nd /var/service/

the UI should show up on the screen, although no data is shown since bitcoind and lnd
are still down.

set up automatic sys updates:

    xbps-install git gnupg
    git clone https://github.com/nakamochi/sysupdates /ssd/sysupdates

import the gpg keys and bump their trust level so that future sysupdates are
accepted:

    gpg --batch --no-tty --import /ssd/sysupdates/keys/*.asc
    for k in 2D301D2E968F0167413E4ACE540189B756BF5B12 DDB61F446A7BC3AF9ECDD92FFDE3E61750E31F2F; do
      echo -e "trust\n5\ny\n" | gpg --batch --no-tty --command-fd 0 --expert --edit-key $k
    done

enable `bitcoind` and `lnd` system services, and run sysupdates script manually
for the first time. it should finish up all the remaining configuration bits:

    for s in bitcoind lnd; do ln -s /etc/sv/$s /var/service/; done
    /ssd/sysupdates/update.sh master

if setting up a dev device, replace `master` with `dev`.

finally, adjust `/boot/config.txt` to the following:

    disable_splash=1
    dtparam=audio=off
    gpu_mem=128
    framebuffer_depth=32
    framebuffer_ignore_alpha=1
    dtoverlay=vc4-fkms-v3d

and `/boot/cmdline.txt`, all on a single line:

    root=/dev/mmcblk0p2 rw rootwait console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 \
    console=tty6 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 loglevel=4 \
    elevator=noop vt.global_cursor_default=0

now, reboot and ssh again into the devices. make sure all services are running.

### creating the final img file

shutdown the device with `poweroff`, plug the SD card into a PC and make an image:

    dd if=/dev/<sdcard> of=path/to/sdcard.img bs=8M

mount the image; the `offset` is the beginning of the second partition in sectors
multiplied by the sector unit, typically 512 bytes:

    mount -o loop -o offset=68157440 path/to/sdcard.img /mnt/img

once mounted, clear logs, shell history, ssh keys and networks
from `/etc/wpa/wpa_supplicant.conf`.

to repare for cloning, replace hostname, RPC pass and its hash back to their respective
placeholders in `/home/bitcoind/mainnet.conf` and `/home/lnd/lnd.mainnet.conf`:
`${hostname.onion}`, `${rpcauth}` and `${rpcauth_hash}`.

remember to unmount the image:

    umount /mnt/img

## cloning

prerequisites:

- an image prepared as described in the "manual uSD card image creation"
- SSD disk used when making that uSD card image
- [mkp224o](https://github.com/cathugger/mkp224o) tool to generate onion service keys ([installation instructions for Ubuntu](docs/mkp224o.md#ubuntu-linux))
- [dcfldd](https://sourceforge.net/projects/dcfldd/) tool if cloning multiple concurrently

grab a new uSD card and copy the image into it:

    dd if=path/to/sdcard.img of=/dev/<new-sdcard> bs=8M

if cloning to multiple cards, use `dcfldd` tool:

    dcfldd if=path/to/sdcard.img of=/dev/foo of=/dev/bar [of=...] bs=8M status=on

after completion, resize the sdcard to its actual size and run `e2fsck -f /dev/...`.

next, clone the SSD in the same way as the uSD card and reduce reserved space:

    tune2fs -r 1000000 /dev/<newly-cloned-ssd-partition-1>

generate 2 onion services, one for bitcoind and one for lnd:

    mkdir -p /tmp/onion
    mkp224o -d /tmp/onion -n 1 b
    mkp224o -d /tmp/onion -n 1 l

mount the SSD:

    mkdir /ssd
    mount /dev/sdd1 /ssd 

copy the generated service directories to the SSD:

    cp -r /tmp/onion/b* /ssd/tor/bitcoind
    cp -r /tmp/onion/l* /ssd/tor/lnd
    chown -R <toruser:torgroup> /ssd/tor

generate a bitcoin RPC auth:

    python tools/rpcauth.py rpc

replace `${rpcauth}` with the generated password, `${rpcauth_hash}` with
the password hash and `${hostname.onion}` with `cat /tmp/onion/b*/hostname`
in `home/bitcoind/mainnet.conf` on the cloned uSD card.

replace `${rpcauth}` with the generated password and `${hostname.onion}` with
`cat /tmp/onion/l*/hostname` in `/home/lnd/lnd.mainnet.conf`.

the uSD card and the associated SSD can now be installed on a device.
