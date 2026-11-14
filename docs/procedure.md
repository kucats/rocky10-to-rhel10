# Procedure

This is the end-to-end procedure, from a running Rocky Linux 10 VPS to a
running RHEL 10 VPS. The commands assume a `config.env` copied from
`examples/config.env.example`.

## 0. Before you start

- **Check the CPU on the VPS.** RHEL 10 needs x86-64-v3:

  ```sh
  /usr/lib64/ld-linux-x86-64.so.2 --help | grep 'x86-64-v3 (supported'
  ```

  No output means **stop**. See [pitfalls](pitfalls.md#cpu-x86-64-v3) for
  what the vCPU model has to do with it.
- **Collect the network settings:** address/prefix, gateway, DNS and the NIC's
  MAC. Take them from the provider panel, or from `ip -br link`,
  `ip -4 addr` and `ip -6 addr` on the VPS.
- **Back up** everything you need off the host: data, `/etc`, crontabs,
  service units, and the SSH host keys if you want to keep the host identity
  (`/etc/ssh/ssh_host_*`).
- **Open the provider console** (VNC or serial) and make sure you can log in
  through it. Know where the panel's "reinstall OS" button is.
- **Download the RHEL 10 KVM guest image** (`rhel-10.x-x86_64-kvm.qcow2`)
  from the Red Hat customer portal.

## 1. Configure

```sh
cp examples/config.env.example config.env
mkdir -p images keys
```

Set `PROVIDER`, `QCOW2`, `HOSTNAME_FQDN`, `NIC_MAC`, the static address
(`IPV4_ADDR`, `IPV4_GW`, `DNS_SERVERS`) if the provider is static, and the
users:

- `ADMIN_USER`: the interactive admin, in `wheel`. Sudo asks for a password.
  Either set `ADMIN_HASHED_PASSWD` (from `openssl passwd -6`, in single
  quotes because `config.env` is sourced by the shell and the hash contains
  `$`), or leave it empty and set the password after the first login.
- `AUTOMATION_USER` (optional): the only user with NOPASSWD sudo, for
  configuration management.
- Key files hold one public key per line.
- `HOSTKEY_DIR` (optional): the old host keys, so clients' `known_hosts`
  stay valid. Then the image contains private keys, so treat the image and
  `WORKDIR` as secrets.

`config.env`, `keys/`, `hostkeys/`, `images/` and `work/` are gitignored.

## 2. Prepare the image

```sh
bin/r2r-prepare-image -c config.env
```

This does the following:

1. Renders the cloud-init seed from `templates/cloud-init/` into
   `work/seed/`, with mode 600. Use `--seed-only` to stop here and review it.
2. Runs `qemu-img convert -O raw` on the qcow2, which gives a raw image of
   about 10 GiB.
3. Finds the root partition with `sfdisk -d`: the largest partition that is
   not BIOS boot or EFI. That is partition 3 in the RHEL KVM image.
4. Loop-mounts the root (`losetup -o <offset> --sizelimit <size>`), natively
   on Linux as root, or otherwise in a privileged helper container
   (`HELPER_IMAGE`, `CONTAINER_CMD`). Then it:
   - adds `nofail,x-systemd.device-timeout=10s` to the `/boot/efi` entry in
     `/etc/fstab` and restores the file's `etc_t` SELinux label;
   - installs the seed into `/var/lib/cloud/seed/nocloud/` (files mode 600,
     files and directories labelled `cloud_var_lib_t`).
5. Compresses the image with `zstd -12 -T0`.
6. Writes `work/<IMAGE_NAME>.manifest` with the raw size and sha256, the zst
   sha256 and the partition offsets. The other tools read it.

## 3. Test locally

```sh
bin/r2r-local-test -c config.env               # normal boot
bin/r2r-local-test -c config.env --break-efi   # also prove /boot/efi nofail
```

This boots `qemu-system-x86_64 -M pc -cpu max -m 1024 -smp 2` on a 50G qcow2
overlay backed by the raw image (so growpart runs; the raw image is not
changed). The NIC is a virtio NIC with the target MAC. For a static
provider, slirp is set to the target subnet with the target gateway
(`-netdev user,net=<subnet>,host=<gw>,hostfwd=tcp:127.0.0.1:2222-<ip>:22`),
so the seed's static configuration is exercised unchanged.

The checks are: sshd answers (and presents the preserved host keys, if
configured), cloud-init finished without errors, the static address is
present, the hostname is set, the root filesystem was grown, the server
offers no password authentication, sudo behaves as configured, Cockpit and
kdump are off, there are no failed units, SELinux is enforcing, and
`/boot/efi` is mounted.

Without KVM (macOS) qemu uses TCG and the first boot takes several minutes.

## 4. Stage on the target

```sh
bin/r2r-stage -c config.env
```

This logs in as `TARGET_SSH` and then runs commands with `TARGET_SUDO`. Sudo
must work without a password prompt (there is no TTY), so either log in as
root with an empty `TARGET_SUDO`, or use a user with NOPASSWD sudo. Then it:

1. copies `bin/r2r-takeover` and the needed libs to `STAGE_DIR`
   (default `/var/tmp/r2r`);
2. runs `dnf -y install zstd ...`, then the preflight checks (see below);
3. allocates a filler file (`FILLER_GB`, default max(12, image GiB + 2)), so
   that the image that follows lands beyond the region to be overwritten;
4. streams the `.zst` onto the target's disk and verifies its sha256;
5. runs `r2r-takeover check`, which maps the staged file's extents and
   requires all of them to start at or above *raw size + 1 GiB*.

If `check` reports an overlap, raise `FILLER_GB` and run `r2r-stage` again.

### Preflight

`lib/os/rocky10.sh` and the provider lib check the following on the target:

| check | failure means |
|---|---|
| OS is Rocky Linux 10, x86_64 | warning (other EL10s are untested) |
| **x86-64-v3 supported** | **hard stop** |
| `TARGET_DISK` is a block device | hard stop |
| stage dir on a plain partition of that disk (not LVM/RAID) | hard stop: the writer reads raw extents |
| stage filesystem is ext4/xfs | warning |
| free space for image + filler + 1 GiB | hard stop |
| disk big enough for image + margin + staged copy | hard stop |
| `/dev/shm`, `/proc/sysrq-trigger`, tools present | hard stop |
| provider: firmware, extra NICs, packet filter | warnings |

## 5. Write

Do this only when the backups are done, the console is open, and nothing
else is using the host. On the target, as root:

```sh
ssh -t <target>
sudo /var/tmp/r2r/bin/r2r-takeover write /var/tmp/r2r/image.raw.zst \
  <ZST_SHA256> <RAW_SHA256> <RAW_BYTES> /dev/vda
```

(`r2r-stage` prints this line with the real values.) It repeats the checks,
asks you to type the hostname, and then starts the writer in the background.
The SSH session drops when the host reboots. A 10 GiB image takes a few
minutes. On the console, follow the `takeover:` kernel messages.

## 6. After the first boot

- Log in as the admin or automation user. Then check `cloud-init status
  --long`, `ip -br addr`, `findmnt /boot/efi`, `getenforce` and
  `systemctl --failed`.
- If `ADMIN_HASHED_PASSWD` was empty, set the admin password (from the
  automation user) so that sudo works.
- Register: `rhc connect` (organization ID and activation key, or user name
  and password). Note that `rhc status` reads stdin, so give it `</dev/null`
  in scripts.
- Consider masking `yggdrasil` (Remote Management) on bastions if you do not
  want the host managed from the Red Hat console.
- Then install the firewall, automatic updates and so on (see the hardening
  ideas in [pitfalls](pitfalls.md#after-the-cutover)), and restore data.
