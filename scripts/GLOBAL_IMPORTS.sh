#!/bin/bash
# shellcheck disable=SC2034,SC2086
set +H
set -e

LOGIN_USER="$(stat -c %U "$(readlink /proc/self/fd/0)")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR is used to make GIT_DIR reliable
cd "${SCRIPT_DIR}" && GIT_DIR=$(git rev-parse --show-toplevel)
source "${GIT_DIR}/configs/settings.sh"

# DEBUG=1 bash ~/dux/scripts/example.sh
if [[ ${DEBUG} -eq 1 ]]; then
	set -x
	cp_flags="-fv"
	mkdir_flags="-pv"
	mv_flags="-fv"
else
	cp_flags="-f"
	mkdir_flags="-p"
	mv_flags="-f"
fi

[[ -z ${DATE:-} ]] &&
	DATE=$(date +"%d-%m-%Y_%H-%M-%S") && export DATE

if [[ ${bootloader_type} -eq 1 ]]; then
	BOOT_CONF="/etc/default/grub" && export BOOT_CONF
elif [[ ${bootloader_type} -eq 2 ]]; then
	BOOT_CONF="/boot/refind_linux.conf" && export BOOT_CONF
fi

[[ -z ${SYSTEMD_USER_ENV:-} ]] &&
	SYSTEMD_USER_ENV="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus XDG_RUNTIME_DIR=/run/user/1000" &&
	export SYSTEMD_USER_ENV

NOT_CHROOT=$(systemd-detect-virt --chroot >&/dev/null) || :

# INITIAL_USER = running from artix-chroot
# LOGIN_USER = not a chroot or permission denied (DENY_SUPERUSER=1)
if [[ ${NOT_CHROOT} -eq 0 ]]; then
	WHICH_USER="${INITIAL_USER}" && export WHICH_USER
elif [[ ${NOT_CHROOT} -eq 1 ]]; then
	WHICH_USER="${LOGIN_USER}" && export WHICH_USER
fi

BACKUPS="/home/${WHICH_USER}/dux_backups" && export BACKUPS

# NOTES:
# trap's EXIT signal is for the Bash instance as a whole, not per "source"d script
_flatpak_silent() {
	flatpak "$@" >&/dev/null
}
_flatpaks_add() {
	[[ -n ${FLATPAKS} ]] &&
		flatpak install --noninteractive flathub ${FLATPAKS}
}
_fix_services_syntax() {
	systemctl daemon-reload
	# "systemctl enable/disable" will fail if trailing whitespace isn't removed
	SERVICES=$(echo ${SERVICES} | xargs) && export SERVICES
}
# Use this '_systemctl' function instead of the 'systemctl' command if reading from ${SERVICES}
_systemctl() {
	if [[ -n ${SERVICES} ]]; then
		_fix_services_syntax
		systemctl "$@"
	fi
}
_move2bkup() {
	local target
	for target in "$@"; do
		if [[ -f ${target} ]]; then
			local parent_dir
			parent_dir=$(dirname "${target}")
			mkdir "${mkdir_flags}" ${BACKUPS}${parent_dir}
			mv "${mv_flags}" "${target}" "${BACKUPS}${target}_${DATE}"

		elif [[ -d ${target} ]]; then
			mv "${mv_flags}" "${target}" "${BACKUPS}${target}_${DATE}"
		fi
	done
}
_pkgs_aur_add() {
	[[ -n ${PKGS_AUR} ]] &&
		# Use -Syu instead of -Syuu for paru.
		sudo -H -u "${WHICH_USER}" bash -c "${SYSTEMD_USER_ENV} DENY_SUPERUSER=1 paru -Syu --aur --quiet --noconfirm --useask --needed --skipreview ${PKGS_AUR}"
}

if [[ ${DENY_SUPERUSER:-} -eq 1 && $(id -u) -ne 1000 ]]; then
	echo -e "\e[1m\nNormal privileges required; don't use sudo or doas!\e[0m\nCurrently affected scripts: \"${BASH_SOURCE[*]}\"\n" >&2
	exit 1
fi

if [[ ${DENY_SUPERUSER:-} -ne 1 && $(id -u) -ne 0 ]]; then
	echo -e "\e[1m\nSuperuser required, prompting if needed...\e[0m\nCurrently affected scripts: \"${BASH_SOURCE[*]}\"\n" >&2
	if hash sudo >&/dev/null; then
		sudo bash "${0}"
		exit $?
	elif hash doas >&/dev/null; then
		doas bash "${0}"
		exit $?
	fi
fi

# Functions requiring superuser
if [[ ${DENY_SUPERUSER:-} -ne 1 && $(id -u) -eq 0 ]]; then
	_pkgs_add() {
		# If ${PKGS} is empty, don't bother doing anything.
		[[ -n ${PKGS} ]] &&
			# Using arrays[@] instead of strings to "fix" shellcheck's SC2086 reduces performance needlessly, as word splitting isn't an issue for both Pacman and Paru
			pacman -Syu --quiet --noconfirm --ask=4 --needed ${PKGS}
	}
	_modify_kernel_parameters() {
		if ! grep -q "${PARAMS}" "${BOOT_CONF}"; then
			if [[ ${bootloader_type} -eq 1 ]]; then
				sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*/& ${PARAMS}/" "${BOOT_CONF}"
				REGENERATE_GRUB2_CONFIG=1
			elif [[ ${bootloader_type} -eq 2 ]]; then
				sed -i -e "s/standard options\"[ ]*\"[^\"]*/& ${PARAMS}/" \
					-e "s/user mode\"[ ]*\"[^\"]*/& ${PARAMS}/" "${BOOT_CONF}"
			fi
		fi
	}
fi
