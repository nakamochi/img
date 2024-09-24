#!/usr/bin/env bash
# shellcheck disable=SC2064

if [[ -z "$2" ]]; then
    echo "Usage: $(basename "$0") [options] img_file mount_point [hostname]"
    echo "Options:"
    echo "  --keep-mount: Do not unmount the image after running the script."
    exit 1
fi

void_url_base="https://repo-default.voidlinux.org/live/current/"
void_image="void-rpi-aarch64-20240314.img.xz"
void_image_sha="b33e1038d27457ba4fcc32bca496c6dd2e6c839bf01ee7d485819b8503aa8099"
# TODO: Calculate offset dynamically
img_rootfs_offset=269484032

ndg_url_base="https://github.com/nakamochi/ndg/releases/download/"
ndg_release="v0.8.1"
ndg_release_sha="d67fd26149dd13900125a6ebfc527028110f8f71dfb2ae311f7a9ca0f99ceff0"

if [[ "$1" == "--keep-mount" ]]; then
    keep_mount="1"
    shift
else
    keep_mount=""
fi

img_file="$1"
img_file_compressed="$img_file.xz"
mount_point="$2"
if [[ -n "$3" ]]; then
    target_hostname="$3"
else
    target_hostname="nakamochi"
fi

img_repodir="$(dirname "$(readlink -m "$0")")"

if [[ ! -d "$mount_point" ]]; then
    sudo mkdir -p "$mount_point"
fi

echo "Adding GPG keys..."
curl "https://raw.githubusercontent.com/nakamochi/sysupdates/dev/keys/x1ddos-540189B756BF5B12.asc" | gpg --import
curl "https://raw.githubusercontent.com/nakamochi/sysupdates/dev/keys/x1ddos-FDE3E61750E31F2F.asc" | gpg --import

if [[ ! -f "$img_file" ]] && [[ ! -f "$img_file_compressed" ]]; then
    echo "Downloading Void Linux image..."
    wget "${void_url_base}${void_image}"
    echo "Verifying image..."
    sha256sum -c <<< "$void_image_sha  $void_image" || exit 1
    echo "Extracting image..."
    mv "$void_image" "$img_file_compressed"
    xz -d "$img_file_compressed"
fi

if [[ "$keep_mount" != "1" ]]; then
    # Be sure to always umount, if user presses Ctrl+C.
    # Two traps are needed to guard against executing commands twice.
    trap "sudo umount -l $mount_point" EXIT
    trap "exit 1" SIGINT SIGTERM
fi

echo "Mounting image..."
sudo mount -o loop -o offset=$img_rootfs_offset "$img_file" "$mount_point" || exit 1
echo "Image mounted at $mount_point"
cd "$mount_point" || exit 1

# Install NDG
sudo mkdir -p "home/uiuser/$ndg_release"
ndg_release_fn="ndg-$ndg_release-aarch64.tar.gz"
if [[ ! -f "/tmp/$ndg_release_fn" ]]; then
    echo "Downloading NDG release..."
    wget -O "/tmp/$ndg_release_fn" "${ndg_url_base}${ndg_release}/$ndg_release_fn"
fi
ndg_gpg_release_sig_fn="ndg-$ndg_release-aarch64.tar.gz.asc"
if [[ ! -f "/tmp/$ndg_gpg_release_sig_fn" ]]; then
    echo "Downloading NDG release signature..."
    wget -O "/tmp/$ndg_gpg_release_sig_fn" "${ndg_url_base}${ndg_release}/$ndg_gpg_release_sig_fn"
fi
echo "Verifying NDG release..."
gpg --verify "/tmp/$ndg_gpg_release_sig_fn" "/tmp/$ndg_release_fn" || exit 1
sha256sum -c <<< "$ndg_release_sha  /tmp/$ndg_release_fn" || exit 1
echo "Installing NDG..."
sudo tar -C "home/uiuser/$ndg_release" --no-same-owner -xf "/tmp/$ndg_release_fn"
sudo mkdir -p etc/sv/nd
sudo cp -r "$img_repodir"/rootfiles/etc/sv/nd/* etc/sv/nd/

echo -n "Enabling few essential services... "
cd "$mount_point/etc/runit/runsvdir/default" || exit 1
for s in chronyd dhcpcd sshd wpa_supplicant; do
    if [[ ! -L "$s" ]]; then
        echo -n "$s "
        sudo ln -s "/etc/sv/$s"
    fi
done
echo ""

#echo "Setting hostname..."
#echo "$target_hostname" > "$mount_point/etc/hostname"

#echo "Tweaking WPASupplicant..."
#echo "passive_scan=1" >> "$mount_point/etc/wpa_supplicant/wpa_supplicant.conf"

if [[ -f ~/.ssh/id_rsa.pub ]]; then
    echo "Adding ssh pubkey..."
    sudo mkdir -p "$mount_point/root/.ssh"
    sudo cp ~/.ssh/id_rsa.pub "$mount_point/root/.ssh/authorized_keys"
fi

echo "Part 1 done."
