# shellcheck shell=bash
# Provider: generic. A template for new providers; copy it to
# lib/provider/<name>.sh and adjust. Every provider lib defines:
#
#   provider_defaults   fill unset config variables with provider defaults
#   provider_notes      print things to know when preparing an image (local)
#   provider_preflight  warnings run ON THE TARGET before staging (as root);
#                       return non-zero only for hard blockers
#
# Variables a provider usually decides:
#   NET_MODE     static | dhcp   (how the VPS gets its address)
#   NIC_NAME     interface name to give the NIC (cloud-init set-name)
#   FIRMWARE     bios | uefi     (how the VM boots the disk)
#   TARGET_DISK  the VM's boot disk as seen by the running source OS

provider_defaults() {
  : "${NET_MODE:=dhcp}"
  : "${NIC_NAME:=ens3}"
  : "${FIRMWARE:=bios}"
  : "${TARGET_DISK:=/dev/vda}"
}

provider_notes() {
  cat >&2 <<'EOF'
provider generic:
  - Confirm the provider gives you a console (VNC/serial) that works without
    the guest network. It is your only window if the new OS does not boot.
  - Confirm how the VM boots (BIOS or UEFI) and whether the address is static
    (set it in the seed) or DHCP.
  - Confirm you can reinstall the source OS from the provider panel: that is
    the recovery path.
EOF
}

provider_preflight() {
  if [ -d /sys/firmware/efi ]; then
    [ "$FIRMWARE" = uefi ] || warn "system booted via UEFI but FIRMWARE=$FIRMWARE"
  else
    [ "$FIRMWARE" = bios ] || warn "system booted via BIOS but FIRMWARE=$FIRMWARE"
  fi
  return 0
}
