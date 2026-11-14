# rocky10-to-rhel10

Turn a VPS that runs **Rocky Linux 10** into **RHEL 10**, for VPS providers
that offer neither RHEL nor a custom ISO install.

How it works: you prepare Red Hat's official RHEL 10 KVM guest image on your
workstation (with a cloud-init seed for the VPS's network and users), boot it
in qemu to check it, copy it onto the running VPS's own disk, and then a small
writer, running from RAM, streams it over that same disk and reboots into
RHEL.

> **This destroys the VPS's current OS.** Back up everything first. Make sure
> the provider gives you a console and a way to reinstall the source OS. That
> is your only way back.

You need a Red Hat subscription that covers the RHEL guest image, for example
the no-cost Developer subscription, and a provider whose terms allow it.

## Layout

```
bin/r2r-prepare-image   qcow2 -> raw, /boot/efi nofail, cloud-init seed, zstd, checksums
bin/r2r-local-test      boot the image in qemu with the target's MAC and subnet, run checks
bin/r2r-stage           copy the writer + image to the target, filler, preflight, check
bin/r2r-takeover        the on-target writer (check / write); self-contained
lib/common.sh           shared helpers, template rendering
lib/os/rocky10.sh       source side: dependencies, preflight (CPU level, layout, space)
lib/os/rhel10.sh        target image: partition detection, fstab, seed paths, SELinux labels
lib/provider/*.sh       provider defaults and caveats (sakura-vps, generic template)
templates/cloud-init/   meta-data, user-data, network-config (static and DHCP)
examples/config.env.example
extras/ssh-legacy       optional: reach SHA-1-only SSH servers from RHEL 10
docs/                   procedure, pitfalls, providers
```

The libraries are split so that other sources, targets and providers can be
added: `lib/os/<os>.sh` for OS-specific code and `lib/provider/<name>.sh` for
the provider's network style, NIC name, firmware and caveats
([docs/providers.md](docs/providers.md)).

## Quick start

```sh
cp examples/config.env.example config.env    # edit: provider, network, users
mkdir -p images keys && cp ~/Downloads/rhel-10.*-x86_64-kvm.qcow2 images/
cp ~/.ssh/id_ed25519.pub keys/admin.pub       # public keys only

bin/r2r-prepare-image -c config.env           # -> work/*.raw, *.raw.zst, *.manifest
bin/r2r-local-test   -c config.env            # qemu boot test
bin/r2r-stage        -c config.env            # upload, preflight, check (no write)
# then, on the target as root, the write command that r2r-stage prints
```

Full walkthrough: [docs/procedure.md](docs/procedure.md).
Things that went wrong before: [docs/pitfalls.md](docs/pitfalls.md).

## Safety model

- **Nothing is written until you run `r2r-takeover write` yourself.**
  `r2r-stage` only uploads and runs `check`.
- **The CPU is checked first.** RHEL 10 needs x86-64-v3. Both preflight and
  the writer refuse to go on without it, because an image that cannot boot
  leaves you with no OS.
- **The staged copy is beyond the overwrite region.** A filler file is
  allocated first, so the uploaded image lands higher on the disk. Then
  `check` maps the file's physical extents with `filefrag` and requires every
  extent to start at or above *image size + 1 GiB*. The filler is a
  heuristic; `check` is the gate.
- **The writer does not depend on the disk it overwrites.** It copies
  `bash`, `zstd`, `dd`, `sha256sum` and their libraries into a tmpfs and runs
  from there. It reads the image straight from the raw disk extents, not
  through the filesystem.
- **The old filesystems cannot write back.** Swap is turned off and services
  are stopped. `sysrq u` remounts everything read-only, and then
  `blockdev --setro` is set on every mounted partition of the disk (a
  read-only mount alone is not enough: see pitfalls). The whole disk stays
  writable for the writer.
- **It verifies before it reboots.** After writing, it hashes the first
  *image size* bytes of the disk and reboots (`sysrq b`) only if the hash
  matches. On a mismatch it checks whether the disk is still changing,
  retries once, and then stops **without rebooting**. Progress goes to
  `/dev/kmsg`, so you can follow it on the provider's console.

## Recovery

- **`check` fails:** nothing has changed. Fix what it reports (usually a
  bigger `FILLER_GB`) and stage again.
- **Verification fails after `write`:** the writer does not reboot. The old
  OS is already damaged, and you will usually have to reinstall from the
  provider panel. The console shows the `takeover:` messages; record them.
- **The new system does not come up:** use the console. Common causes are a
  wrong MAC, address or gateway in the seed (log in on the console and check
  `cloud-init status --long` and `/var/log/cloud-init.log`). A damaged EFI
  partition is a non-issue here, because `/boot/efi` is `nofail`.
- **Worst case:** reinstall the source OS (Rocky Linux 10) from the provider
  panel, fix the image or the seed, and repeat. Test locally first.

## Requirements

- Workstation: bash, `qemu-img`, `qemu-system-x86_64` (for the test), `zstd`,
  `ssh`. To modify the image you need either Linux as root (`sfdisk`,
  `losetup`, `setfattr`, XFS support) or docker/podman with a privileged Linux
  helper container. On macOS, colima works; keep `WORKDIR` under a directory
  that is shared into the VM.
- Target: Rocky Linux 10 x86_64 on a plain partition of a virtio disk (no
  LVM for the staging filesystem), root access, enough free space for the
  filler plus the compressed image, and a vCPU with x86-64-v3.

## Development

`make lint` runs `bash -n` over every script, plus `shellcheck` when it is
installed. `make scan` looks for real IPv4 addresses, MACs, keys and password
hashes, and should be run before every push. There is no CI.

## License

MIT, see [LICENSE](LICENSE). RHEL and the RHEL KVM guest image are
Red Hat's and are subject to your subscription terms; they are not part of
this repository.
