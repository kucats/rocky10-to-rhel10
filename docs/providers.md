# Providers

A provider library (`lib/provider/<name>.sh`) holds what depends on the VPS
product rather than on the OS. Select it with `PROVIDER=<name>` in
`config.env`.

| variable | meaning |
|---|---|
| `NET_MODE` | `static` (address in the seed) or `dhcp` |
| `NIC_NAME` | name given to the NIC (matched by MAC, `set-name`) |
| `FIRMWARE` | `bios` or `uefi` |
| `TARGET_DISK` | boot disk as seen by the running source OS |

Functions:

- `provider_defaults` fills unset variables (config values win).
- `provider_notes` prints reminders during `r2r-prepare-image`.
- `provider_preflight` runs on the target during `r2r-stage`, as root. It
  prints warnings and returns non-zero only for hard blockers.

To add a provider, copy `lib/provider/generic.sh` and adjust it. Put only
generic product behaviour in it, never account details.

## sakura-vps

Sakura VPS (Japan), as observed in 2026:

- RHEL is not in the standard OS list. Customer ISO installation and
  scale-up were temporarily suspended in October-November 2026, which is why
  this toolkit exists.
- The network is static (address, gateway and DNS are shown in the panel),
  so `NET_MODE=static`.
- The machine type is i440FX with BIOS boot, so `FIRMWARE=bios`. The image's
  EFI partition is unused, and `/boot/efi` is made `nofail`.
- NICs: `ens3` is the public interface. `ens4`/`ens5` appear when local
  network options are attached; the seed stops NetworkManager from creating
  DHCP profiles for them.
- The panel's packet filter sits in front of the VM and survives the OS
  change. Keep SSH allowed.
- The panel's Rocky Linux 10 image uses a `rocky` admin user with sudo. Use
  `TARGET_SSH=rocky@<address>` and `TARGET_SUDO=sudo` for staging.
- vCPU model: see [pitfalls](pitfalls.md#cpu-x86-64-v3). On older servers a
  panel OS reinstall changed the presented model to a v3-capable one; a stop
  and start did not.
- Recovery is a panel OS reinstall of Rocky Linux 10.

## generic

A template that defaults to DHCP, `ens3`, BIOS and `/dev/vda`. Check every
value against your provider.
