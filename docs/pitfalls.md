# Pitfalls and findings

These were learned by doing this conversion for real (RHEL 10.3, cloud-init
24.4, 1 GB VPSes). They are observations, not guarantees.

## Why an image and not the installer

On a 1 GB VPS the RHEL 10 Anaconda installer is unreliable: it runs out of
memory or crawls. A prepared KVM guest image with a cloud-init seed needs no
installer, boots in about a minute, and can be tested locally first.

## CPU: x86-64-v3

RHEL 10 is built for x86-64-v3 (AVX2, BMI1/2, F16C, FMA, LZCNT, MOVBE). On a
CPU without v3 it does not boot at all. Check on the running VPS:

```sh
/usr/lib64/ld-linux-x86-64.so.2 --help | grep 'x86-64-v3 (supported'
```

On a VPS, the **vCPU model that the hypervisor presents** matters, not the
physical CPU. One observation on Sakura VPS: an older server presented a
QEMU "Broadwell" model without F16C/LZCNT (so v2 only). A panel stop/start
did not change it. A panel OS reinstall of Rocky Linux 10 did switch it to a
v3-capable model, while keeping the IP, MAC and BIOS platform. Newer servers
presented the host CPU with v3 from the start. Don't rely on this; check
after every change, and ask the provider if v3 does not appear.

## A read-only remount is not enough

The first real attempt failed verification. After `sysrq u` had remounted
everything read-only, the old ext4 hit errors (its blocks were being
overwritten under it) and its error path **rewrote its superblock anyway**.
The old `/boot` partition started exactly where the new image's EFI
partition is, so the write landed in the new EFI partition and the verify
failed. The writer refused to reboot, as designed. A forced restart then
stopped in emergency mode over `/boot/efi`.

The fix is to run `blockdev --setro` on **every mounted partition** of the
target disk after `sysrq u` (not on the whole disk, which the writer needs).
With that, the write verified and the host booted RHEL. The `nofail` on
`/boot/efi` is the second line of defence.

## cloud-init (24.4) seed details

- network-config v2: the IPv4 default route must be written `to: 0.0.0.0/0`.
  cloud-init 24.4 rejects `to: default`.
- Match the NIC by MAC and give it a name with `set-name`.
- For IPv6 on providers that route via a link-local gateway, use `via: fe80::1`
  (or whatever the provider documents) with `to: "::/0"`.
- cloud-init gives a user's primary group the **next free GID**, not
  uid = gid. The seed's `runcmd` fixes this with `groupmod` and `chown`.
- To keep a host identity, pass the old keys as `ssh_keys`
  (`<type>_private` / `<type>_public`) with `ssh_deletekeys: true` and
  `ssh_genkeytypes: []`.
- Extra NICs (provider local networks) get automatic DHCP profiles from
  NetworkManager, and those make `NetworkManager-wait-online` fail. The seed
  writes `no-auto-default=*`.
- **kdump** cannot reserve `crashkernel` memory on 1 GB, so it is disabled.
- The KVM image enables **Cockpit**, which listens publicly on TCP 9090, so
  `cockpit.socket` is disabled.
- `sed -i` on a file inside the mounted image replaces the file and drops its
  SELinux label. Restore it with `setfattr -n security.selinux -v <label>`
  (`etc_t` for `/etc/fstab`, `cloud_var_lib_t` for the seed). Otherwise the
  first boot has wrong labels.

## RHEL 10 differences that bite scripts

- There is **no `ssh_keys` group**: host private keys are `root:root 0600`.
  Configuration that sets `group: ssh_keys` fails.
- `nmcli -g` escapes `:` in IPv6 values (`2001\:db8\:\:1`). Use `ip -6` for
  checks.
- The npm package is `nodejs-npm`.
- The Salt onedir `salt-call` lives at `/opt/saltstack/salt/salt-call`.
- `rhc status` reads stdin; give it `</dev/null` in scripts and over SSH.

## Legacy SSH peers (SHA-1)

The DEFAULT crypto policy makes OpenSSL reject SHA-1 signatures. Old servers
that offer only `ssh-rsa` host keys (or SHA-1 key exchange) then fail even
with `+ssh-rsa`. Don't lower the system policy. Instead, scope it to one
process:

- `extras/ssh-legacy` runs `ssh` (or `scp`, through a `scp-legacy` symlink)
  with a private `OPENSSL_CONF`. That config includes the system config plus
  `rh-allow-sha1-signatures = yes` in the `evp_properties` section. It also
  adds `+ssh-rsa` and the SHA-1 key exchanges.
- For a long-lived alias, add a per-host drop-in instead, and still run it
  through the wrapper. Give it a number below the crypto-policy include
  (`50-redhat.conf`), because the first value read wins:

  ```
  # /etc/ssh/ssh_config.d/05-legacy.conf
  Match host legacy.example.net
      HostKeyAlgorithms +ssh-rsa
      PubkeyAcceptedAlgorithms +ssh-rsa
      KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1
  ```

## After the cutover

- Register with `rhc connect` before you install packages from Red Hat
  repositories.
- On bastions, consider masking `yggdrasil` (Remote Management) if you do not
  manage the host from the Red Hat console.
- Hardening that worked well on a 1 GB bastion:
  - sshd key-only (`PasswordAuthentication no`,
    `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`),
    `PermitRootLogin no`, `MaxAuthTries 3`, `LoginGraceTime 30`,
    `MaxStartups 10:30:60`, `AllowGroups`
  - firewalld with the public zone limited to what you serve
  - `dnf-automatic` for security errata
  - SELinux enforcing, with the crypto policy kept at DEFAULT
- **IPv6 and IPv4 allowlists:** when you enable IPv6 on a host whose outbound
  connections are allowlisted by IPv4 address elsewhere, prefer IPv4 for
  outbound in `/etc/gai.conf` (`precedence ::ffff:0:0/96 100`). Otherwise
  those peers suddenly see an IPv6 source address and refuse it.
