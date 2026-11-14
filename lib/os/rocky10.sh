# shellcheck shell=bash
# Source OS: Rocky Linux 10 (the running system that gets overwritten).
# These functions run ON THE TARGET, as root, before anything is written.

rocky10_packages="zstd e2fsprogs util-linux coreutils"

rocky10_install_deps() {
  # shellcheck disable=SC2086
  dnf -y install $rocky10_packages
}

# rocky10_preflight <stage-dir> <raw-bytes> <zst-bytes> <filler-bytes>
# Hard failures return non-zero; soft findings are warnings.
rocky10_preflight() {
  local dir=$1 raw=$2 zst=$3 filler=$4 rc=0 id ver src disk need avail mem
  is_root || die "preflight must run as root"

  id=$(. /etc/os-release && echo "$ID"); ver=$(. /etc/os-release && echo "$VERSION_ID")
  case "$id:$ver" in
    rocky:10*) log "source OS: Rocky Linux $ver" ;;
    *) warn "source OS is $id $ver, not Rocky Linux 10 (untested)" ;;
  esac
  [ "$(uname -m)" = x86_64 ] || { warn "not x86_64"; rc=1; }

  if x86_64_v3_supported; then
    log "x86-64-v3: supported"
  else
    warn "x86-64-v3 is NOT supported by this vCPU: RHEL 10 cannot boot here."
    warn "Do not write. Check: /usr/lib64/ld-linux-x86-64.so.2 --help | grep x86-64-v3"
    rc=1
  fi

  disk=$(readlink -f "$TARGET_DISK")
  [ -b "$disk" ] || { warn "TARGET_DISK $TARGET_DISK is not a block device"; return 1; }
  log "target disk $disk: $(lsblk -dno SIZE "$disk")"
  lsblk -o NAME,START,SIZE,FSTYPE,MOUNTPOINTS "$disk" >&2 || true

  mkdir -p "$dir"
  src=$(readlink -f "$(findmnt -n -o SOURCE --target "$dir")")
  case $src in
    /dev/mapper/*|/dev/dm-*|/dev/md*)
      warn "stage dir $dir is on $src (LVM/RAID): the writer needs a plain partition of $disk"
      rc=1 ;;
    "$disk"*) log "stage dir $dir is on $src" ;;
    *) warn "stage dir $dir is on $src, not on $disk"; rc=1 ;;
  esac
  case $(findmnt -n -o FSTYPE --target "$dir") in
    ext4|xfs) ;;
    *) warn "stage filesystem is not ext4/xfs; filefrag extent mapping is untested there" ;;
  esac

  need=$(( zst + filler + R2R_GIB ))
  avail=$(( $(df -P -k "$dir" | awk 'NR==2 {print $4}') * 1024 ))
  if [ "$avail" -lt "$need" ]; then
    warn "free space in $dir: $avail bytes, need about $need (image + filler + 1 GiB)"
    rc=1
  fi
  if [ "$(lsblk -bdno SIZE "$disk")" -lt $(( raw + R2R_GIB + zst )) ]; then
    warn "disk is too small to hold the image plus a staged copy beyond it"; rc=1
  fi

  mem=$(awk '/^MemTotal/ {print int($2/1024)}' /proc/meminfo)
  log "memory: ${mem} MiB (the writer runs from a small tmpfs; 1 GB is enough)"

  grep -q ' /dev/shm ' /proc/mounts || { warn "/dev/shm is not mounted"; rc=1; }
  [ -w /proc/sysrq-trigger ] || { warn "/proc/sysrq-trigger not writable"; rc=1; }
  local t
  for t in zstd sha256sum filefrag dd findmnt blockdev setsid ldd; do
    command -v "$t" >/dev/null 2>&1 || { warn "missing tool $t (run install-deps)"; rc=1; }
  done
  return $rc
}
