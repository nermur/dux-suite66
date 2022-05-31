#!/bin/bash
set +H
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}" && GIT_DIR=$(git rev-parse --show-toplevel)
source "${GIT_DIR}/scripts/GLOBAL_IMPORTS.sh"
source "${GIT_DIR}/configs/settings.sh"

GDM_CONF="/etc/gdm/custom.conf"

_setup_gdm() {
	_move2bkup "${GDM_CONF}" &&
		cp "${cp_flags}" "${GIT_DIR}"/files/etc/gdm/custom.conf "/etc/gdm/"

	sed -i "s/AutomaticLogin=~GNOME.sh~/AutomaticLogin=${WHICH_USER}/" "${GDM_CONF}"

	[[ ${gdm_auto_login} -eq 1 ]] &&
		sed -i "s/AutomaticLoginEnable=.*/AutomaticLoginEnable=True/" "${GDM_CONF}"

	[[ ${gdm_disable_wayland} -eq 1 ]] &&
		sed -i '/^#WaylandEnable/s/^#//' "${GDM_CONF}"

	systemctl disable entrance.service lightdm.service lxdm.service sddm.service xdm.service
	SERVICES+="gdm.service "
}

PKGS="gdm libnm libnma "
_pkgs_add
PKGS=""

PKGS+="gnome-backgrounds gnome-themes-extra gnome-shell gnome-shell-extensions gnome-session gnome-control-center networkmanager \
gnome-clocks gnome-weather gnome-tweaks \
gsettings-desktop-schemas xdg-desktop-portal xdg-desktop-portal-gtk ibus xdg-desktop-portal-gnome \
konsole kconfig seahorse aspell aspell-en "

_setup_gdm
_pkgs_add

SERVICES+="NetworkManager.service " &&
	systemctl disable connman.service systemd-networkd.service
# shellcheck disable=SC2086
_systemctl enable ${SERVICES}
