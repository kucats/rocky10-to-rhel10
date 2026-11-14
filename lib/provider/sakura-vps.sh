# shellcheck shell=bash
# Provider: Sakura VPS (Japan). See lib/provider/generic.sh for the interface.
#
# Product behaviour this relies on (observed 2026; check it is still true):
#   - RHEL is not in the standard OS list. Customer ISO install and scale-up
#     were temporarily suspended from October 2026, so neither a RHEL ISO nor
#     a bigger plan for the 1 GB installer was an option.
#   - The network is static, as shown in the control panel (address, prefix,
#     gateway, DNS). There is no DHCP for the public interface.
#   - Machine type is i440FX with a SeaBIOS-style BIOS boot (no UEFI).
#   - virtio NICs appear as ens3 (public), ens4/ens5 (local network options).
#   - The panel's packet filter option sits in front of the VM and is kept
#     across an OS change: keep SSH allowed there.
#   - The panel's Rocky Linux image logs in as the "rocky" admin user with sudo.

provider_defaults() {
  : "${NET_MODE:=static}"
  : "${NIC_NAME:=ens3}"
  : "${FIRMWARE:=bios}"
  : "${TARGET_DISK:=/dev/vda}"
}

provider_notes() {
  cat >&2 <<'EOF'
provider sakura-vps:
  - Copy address/prefix/gateway/DNS and the ens3 MAC from the control panel
    (or from `ip -br link` / `ip -4 addr` on the running Rocky system).
  - The VM boots via BIOS: the image's /boot/efi entry is made nofail.
  - Keep the VNC console open in the panel during the write; progress goes to
    the kernel log, which the console shows.
  - Recovery: reinstall Rocky Linux 10 from the panel, then retry.
EOF
}

provider_preflight() {
  local rc=0 model
  model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)
  if ! x86_64_v3_supported; then
    warn "vCPU '$model' does not offer x86-64-v3; RHEL 10 will not boot."
    warn "Observed on Sakura VPS: older servers presented a 'Broadwell' model"
    warn "without F16C/LZCNT. A panel stop/start did not change it; a panel"
    warn "OS reinstall of Rocky Linux 10 did switch it to a v3-capable model."
    warn "This is an observation, not a guarantee; ask support if needed."
    rc=1
  fi
  if [ -d /sys/firmware/efi ]; then
    warn "booted via UEFI, which is unexpected on Sakura VPS"
  fi
  if ip -br link 2>/dev/null | grep -Eq '^ens[45] '; then
    warn "extra NICs (ens4/ens5) present: the seed sets NetworkManager"
    warn "no-auto-default=* so they do not stall NetworkManager-wait-online"
  fi
  warn "make sure the panel packet filter (if enabled) allows SSH"
  return $rc
}
