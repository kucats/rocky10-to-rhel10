# shellcheck shell=bash
# Target OS: RHEL 10 KVM guest image (rhel-10.x-x86_64-kvm.qcow2).
#
# Image layout (RHEL 10.x KVM image): GPT, p1 BIOS boot, p2 EFI (vfat,
# /boot/efi), p3 root (XFS). Offsets are detected, never hardcoded.
# Seed facts were verified with cloud-init 24.4 on RHEL 10.3.

rhel10_seed_dir=/var/lib/cloud/seed/nocloud
rhel10_seed_label=system_u:object_r:cloud_var_lib_t:s0
rhel10_etc_label=system_u:object_r:etc_t:s0
rhel10_efi_type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
rhel10_biosboot_type=21686148-6449-6E6F-744E-656564454649

# rhel10_partitions <raw> : print "num start_bytes size_bytes type" per partition.
rhel10_partitions() {
  sfdisk -d "$1" | awk '
    /^sector-size:/ { ss = $2 }
    /: start=/ {
      n = $1; sub(/.*[^0-9]/, "", n)
      s = $0; sub(/.*start= */, "", s); sub(/,.*/, "", s)
      z = $0; sub(/.*size= */, "", z); sub(/,.*/, "", z)
      t = $0; sub(/.*type= */, "", t); sub(/,.*/, "", t)
      if (!ss) ss = 512
      printf "%s %.0f %.0f %s\n", n, s * ss, z * ss, toupper(t)
    }'
}

# rhel10_find_parts <raw> : sets ROOT_PART ROOT_OFFSET ROOT_SIZE EFI_PART EFI_OFFSET EFI_SIZE.
# Root = the largest partition that is neither BIOS boot nor EFI.
rhel10_find_parts() {
  local n s z t
  ROOT_SIZE=0 EFI_PART=""
  while read -r n s z t; do
    case $t in
      "$rhel10_efi_type") EFI_PART=$n EFI_OFFSET=$s EFI_SIZE=$z ;;
      "$rhel10_biosboot_type") ;;
      *) if [ "$z" -gt "$ROOT_SIZE" ]; then ROOT_PART=$n ROOT_OFFSET=$s ROOT_SIZE=$z; fi ;;
    esac
  done <<EOF
$(rhel10_partitions "$1")
EOF
  [ "$ROOT_SIZE" -gt 0 ] || die "no root partition found in $1"
  [ -n "$EFI_PART" ] || warn "no EFI partition found in $1"
  [ "$ROOT_PART" = 3 ] || warn "root is partition $ROOT_PART, expected 3 for the RHEL KVM image"
  log "root: partition $ROOT_PART offset $ROOT_OFFSET size $ROOT_SIZE; efi: partition ${EFI_PART:-none} offset ${EFI_OFFSET:-}"
}

# rhel10_fstab_nofail <mounted-root> : make /boot/efi optional (BIOS VPSes do
# not need it, and a damaged EFI partition must not stop the boot).
rhel10_fstab_nofail() {
  local f=$1/etc/fstab tmp
  [ -f "$f" ] || die "no $f"
  tmp=$(mktemp)
  awk '$2 == "/boot/efi" && $4 !~ /nofail/ { $4 = $4 ",nofail,x-systemd.device-timeout=10s" } { print }' \
    "$f" > "$tmp"
  # Overwrite in place (keeps the inode); restore the label anyway, because
  # tools like sed -i replace the file and drop it.
  cat "$tmp" > "$f"; rm -f "$tmp"
  setfattr -n security.selinux -v "$rhel10_etc_label" "$f"
  grep -q '/boot/efi.*nofail' "$f" || warn "/boot/efi entry not found in fstab"
  grep '/boot/efi' "$f" >&2 || true
}

# rhel10_install_seed <mounted-root> <seed-src-dir>
rhel10_install_seed() {
  local root=$1 src=$2 d=$1$rhel10_seed_dir f
  mkdir -p "$d"
  chmod 0700 "$d"
  for f in meta-data user-data network-config; do
    [ -f "$src/$f" ] || die "seed file $src/$f missing"
    install -m 0600 -o 0 -g 0 "$src/$f" "$d/$f"
  done
  for f in "$root/var/lib/cloud/seed" "$d" "$d/meta-data" "$d/user-data" "$d/network-config"; do
    setfattr -n security.selinux -v "$rhel10_seed_label" "$f"
  done
  ls -la "$d" >&2
}

# ---- seed rendering (runs locally, portable) ----

# Emit one cloud-init users entry.
#   name uid groups keys_file hashed_passwd sudo(yes|no)
rhel10_user_block() {
  local name=$1 uid=$2 groups=$3 keys=$4 hash=$5 sudo=$6 k
  grep -Evq '^[[:space:]]*(#|$)' "$keys" || die "no public keys in $keys"
  printf '  - name: %s\n    uid: %s\n    shell: /bin/bash\n' "$name" "$uid"
  [ -n "$groups" ] && printf '    groups: [%s]\n' "$(printf '%s' "$groups" | sed 's/ \{1,\}/, /g')"
  if [ -n "$hash" ]; then
    printf '    lock_passwd: false\n    hashed_passwd: %s\n' "$(yaml_sq "$hash")"
  else
    printf '    lock_passwd: true\n'
  fi
  [ "$sudo" = yes ] && printf "    sudo: 'ALL=(ALL) NOPASSWD:ALL'\n"
  printf '    ssh_authorized_keys:\n'
  grep -Ev '^[[:space:]]*(#|$)' "$keys" | while IFS= read -r k; do
    printf '      - %s\n' "$(yaml_sq "$k")"
  done
}

# Host keys to preserve: <dir> holding ssh_host_<type>_key and .pub
rhel10_hostkeys_block() {
  local dir=$1 t n=0
  for t in rsa ecdsa ed25519; do
    [ -f "$dir/ssh_host_${t}_key" ] && [ -f "$dir/ssh_host_${t}_key.pub" ] && n=$((n + 1))
  done
  # Without keys, ssh_genkeytypes: [] would leave sshd with no host key at all.
  [ "$n" -gt 0 ] || die "HOSTKEY_DIR $dir holds no ssh_host_<type>_key + .pub pair"
  printf 'ssh_deletekeys: true\nssh_genkeytypes: []\nssh_keys:\n'
  for t in rsa ecdsa ed25519; do
    [ -f "$dir/ssh_host_${t}_key" ] && [ -f "$dir/ssh_host_${t}_key.pub" ] || continue
    printf '  %s_private: |\n' "$t"
    sed 's/^/    /' "$dir/ssh_host_${t}_key"
    printf '  %s_public: %s\n' "$t" "$(yaml_sq "$(awk '{print $1" "$2}' "$dir/ssh_host_${t}_key.pub")")"
  done
}

# rhel10_render_seed <outdir> : uses config variables, writes meta-data,
# user-data, network-config (mode 600).
rhel10_render_seed() {
  local out=$1 b tmpl kf
  b=$(mktemp -d "${TMPDIR:-/tmp}/r2r.XXXXXX")
  umask 077
  mkdir -p "$out"

  export R2R_T_HOSTNAME=$HOSTNAME_FQDN
  export R2R_T_HOSTNAME_SHORT=${HOSTNAME_FQDN%%.*}
  export R2R_T_INSTANCE_ID=${INSTANCE_ID:-r2r-${HOSTNAME_FQDN%%.*}-$(date -u +%Y%m%d%H%M%S)}
  export R2R_T_NIC_NAME=$NIC_NAME R2R_T_NIC_MAC=$NIC_MAC
  export R2R_T_IPV4_ADDR=${IPV4_ADDR:-} R2R_T_IPV4_GW=${IPV4_GW:-}
  export R2R_T_DNS_LIST
  R2R_T_DNS_LIST=$(printf '%s' "${DNS_SERVERS:-}" | sed 's/^ *//; s/ *$//; s/ \{1,\}/, /g')

  # users + runcmd GID fixes (cloud-init gives the primary group the next
  # free GID, not uid=gid)
  kf=$(cfg_path "$ADMIN_KEYS_FILE")
  [ -s "$kf" ] || die "ADMIN_KEYS_FILE $kf is empty or missing"
  rhel10_user_block "$ADMIN_USER" "$ADMIN_UID" "${ADMIN_GROUPS:-wheel}" "$kf" \
    "${ADMIN_HASHED_PASSWD:-}" no > "$b/USERS"
  printf '  - [sh, -c, %s]\n' \
    "$(yaml_sq "[ \"\$(id -g $ADMIN_USER)\" = $ADMIN_UID ] || { groupmod -g $ADMIN_UID $ADMIN_USER && chown -R $ADMIN_USER:$ADMIN_USER /home/$ADMIN_USER; }")" \
    > "$b/RUNCMD"
  if [ -n "${AUTOMATION_USER:-}" ]; then
    kf=$(cfg_path "$AUTOMATION_KEYS_FILE")
    [ -s "$kf" ] || die "AUTOMATION_KEYS_FILE $kf is empty or missing"
    rhel10_user_block "$AUTOMATION_USER" "$AUTOMATION_UID" "${AUTOMATION_GROUPS:-}" "$kf" "" yes >> "$b/USERS"
    printf '  - [sh, -c, %s]\n' \
      "$(yaml_sq "[ \"\$(id -g $AUTOMATION_USER)\" = $AUTOMATION_UID ] || { groupmod -g $AUTOMATION_UID $AUTOMATION_USER && chown -R $AUTOMATION_USER:$AUTOMATION_USER /home/$AUTOMATION_USER; }")" \
      >> "$b/RUNCMD"
  fi

  if [ -n "${HOSTKEY_DIR:-}" ]; then
    rhel10_hostkeys_block "$(cfg_path "$HOSTKEY_DIR")" > "$b/SSH_KEYS"
  else
    printf '# host keys: generated on first boot\n' > "$b/SSH_KEYS"
  fi

  # optional IPv6 (static)
  if [ -n "${IPV6_ADDR:-}" ]; then
    printf '      - %s\n' "$IPV6_ADDR" > "$b/IPV6_ADDRESS"
    printf '      - to: "::/0"\n        via: %s\n' "${IPV6_GW:-fe80::1}" > "$b/IPV6_ROUTE"
  else
    : > "$b/IPV6_ADDRESS"; : > "$b/IPV6_ROUTE"
  fi
  # empty blocks: give awk one blank-free line to read
  for tmpl in IPV6_ADDRESS IPV6_ROUTE; do [ -s "$b/$tmpl" ] || printf '      # (no IPv6)\n' > "$b/$tmpl"; done

  case $NET_MODE in
    static) tmpl=network-config.tmpl ;;
    dhcp)   tmpl=network-config-dhcp.tmpl ;;
    *) die "NET_MODE must be static or dhcp" ;;
  esac
  r2r_render "$R2R_ROOT/templates/cloud-init/meta-data.tmpl" "$out/meta-data" "$b"
  r2r_render "$R2R_ROOT/templates/cloud-init/user-data.tmpl" "$out/user-data" "$b"
  r2r_render "$R2R_ROOT/templates/cloud-init/$tmpl" "$out/network-config" "$b"
  chmod 600 "$out"/*
  rm -rf "$b"
}
