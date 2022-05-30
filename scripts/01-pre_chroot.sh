#!/bin/bash
# shellcheck disable=SC2162
set +H
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}" && GIT_DIR=$(git rev-parse --show-toplevel)

source "${GIT_DIR}/scripts/GLOBAL_IMPORTS.sh"
source "${GIT_DIR}/configs/settings.sh"

clear

if [[ ! $(hostname) = "artix-live" ]]; then
	echo -e "\nERROR: Do not run this script outside of the Artix Linux ISO!\n"
	exit 1
fi
if cryptsetup status "lukspart" | grep -q "inactive"; then
	echo -e "\nERROR: Forgot to mount the LUKS2 partition as 'lukspart'?\n"
	exit 1
fi

[[ -z ${BOOT_PART:-} ]] &&
	BOOT_PART=$(blkid | sed -n '/BOOTEFI/p' | cut -f1 -d' ' | tr -d :) && export BOOT_PART

LUKS_PART="/dev/mapper/lukspart"
SUBVOL_LIST=(root btrfs srv snapshots pkg log home)

_make_dirs() {
	mkdir "${mkdir_flags}" /mnt/{boot,btrfs,var/{log,cache/pacman/pkg},srv,.snapshots,root,home}
}

# If the Btrfs filesystem doesn't exist on the partition containing "lukspart", create it.
if ! lsblk -fl | grep --line-buffered "lukspart" | grep -q "btrfs"; then
	umount -flRq /mnt || :
	mkfs.btrfs "${LUKS_PART}"
	mount -t btrfs "${LUKS_PART}" /mnt

	_make_dirs
	mount -t vfat -o nodev,nosuid,noexec "${BOOT_PART}" /mnt/boot

	_make_subvolumes() {
		for subvols in "${SUBVOL_LIST[@]}"; do
			btrfs subvolume create /mnt/@"${subvols}"
		done
	}
	_make_subvolumes
fi

_mount_partitions() {
	umount -flRq /mnt || :

	# Why 'noatime': https://archive.is/wjH73
	local OPTS="noatime,compress=zstd:1"

	mount -t btrfs -o "${OPTS}",subvol=@root "${LUKS_PART}" /mnt &&
		_make_dirs # Incase one of these directories was removed.

	mount -t vfat -o nodev,nosuid,noexec "${BOOT_PART}" /mnt/boot

	mount -t btrfs -o "${OPTS}",subvolid=5 "${LUKS_PART}" /mnt/btrfs
	mount -t btrfs -o "${OPTS}",subvol=@srv "${LUKS_PART}" /mnt/srv
	mount -t btrfs -o "${OPTS}",subvol=@snapshots "${LUKS_PART}" /mnt/.snapshots
	mount -t btrfs -o "${OPTS}",subvol=@pkg "${LUKS_PART}" /mnt/var/cache/pacman/pkg
	mount -t btrfs -o "${OPTS}",subvol=@log "${LUKS_PART}" /mnt/var/log
	mount -t btrfs -o "${OPTS}",subvol=@home "${LUKS_PART}" /mnt/home
}
_mount_partitions

pacman -S --noconfirm --ask=4 pacman-contrib artix-archlinux-support
if [[ ${DEBUG} -ne 1 ]]; then
	echo -e "\nTesting which mirrors have the shortest response time, please wait...\n"
	# shellcheck disable=SC2086,SC2312
	curl -s "https://gitea.artixlinux.org/packagesA/artix-mirrorlist/raw/branch/master/x86_64/core/mirrorlist" |
		sed -e 's/^#Server/Server/' -e '/^#/d' |
		rankmirrors -v -n 5 --max-time ${mirror_timeout} - |
		tee /etc/pacman.d/mirrorlist
fi

sed -i "/\[lib32\]/,/Include/"'s/^#//' /etc/pacman.conf

MLIST="Include = /etc/pacman.d/mirrorlist-arch"
if ! pcregrep -q -M "\[extra\].*\n.*${MLIST}" /etc/pacman.conf; then
	echo -e "\n[extra]\n${MLIST}\n" >>/etc/pacman.conf
fi
if ! pcregrep -q -M "\[community\].*\n.*${MLIST}" /etc/pacman.conf; then
	echo -e "\n[community]\n${MLIST}\n" >>/etc/pacman.conf
fi
if ! pcregrep -q -M "\[multilib\].*\n.*${MLIST}" /etc/pacman.conf; then
	echo -e "\n[multilib]\n${MLIST}\n" >>/etc/pacman.conf
fi

# Fixes an edge case stemming from Pacman suddenly exiting (due to the user pressing Ctrl + C, which sends SIGINT).
rm -f /mnt/var/lib/pacman/db.lck

# Keep packages here to a minimum; packages are to be installed later if possible.
basestrap /mnt artix-archlinux-support lib32-artix-archlinux-support \
	cryptsetup dosfstools btrfs-progs base base-devel git \
	66 elogind-suite66 \
	zsh grml-zsh-config --quiet --noconfirm --ask=4 --needed

# GnuPG can't use systemd-resolved's selected "nameserver"(s) without this symlink; prevents installation issues.
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

cat <<'EOF' >/mnt/etc/fstab
# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
EOF
fstabgen -U /mnt >>/mnt/etc/fstab

echo -e "# Some useful configuration is gone if this isn't mounted\ndebugfs    /sys/kernel/debug      debugfs  defaults  0 0" >>/mnt/etc/fstab

sed -i -e 's/^#Color/Color/' \
	-e '/^#ParallelDownloads/s/^#//' /mnt/etc/pacman.conf
