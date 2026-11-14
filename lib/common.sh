# shellcheck shell=bash
# Shared helpers for the r2r tools. Sourced, never executed.

R2R_GIB=$((1024 * 1024 * 1024))

log()  { printf '== %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

is_linux() { [ "$(uname -s)" = Linux ]; }
is_root()  { [ "$(id -u)" = 0 ]; }

# Load a config file (shell variable assignments) and the OS/provider libs.
# Sets R2R_ROOT-relative paths; callers must set R2R_ROOT first.
r2r_load_config() {
  local cfg=${1:-${R2R_CONFIG:-./config.env}}
  [ -f "$cfg" ] || die "config file not found: $cfg (copy examples/config.env.example)"
  # shellcheck disable=SC1090
  . "$cfg"
  R2R_CONFIG_DIR=$(cd "$(dirname "$cfg")" && pwd)
  : "${SOURCE_OS:=rocky10}" "${TARGET_OS:=rhel10}" "${PROVIDER:=generic}"
  r2r_load_libs
  provider_defaults
}

r2r_load_libs() {
  local f
  for f in "os/$SOURCE_OS" "os/$TARGET_OS" "provider/$PROVIDER"; do
    [ -f "$R2R_ROOT/lib/$f.sh" ] || die "no library lib/$f.sh"
    # shellcheck disable=SC1090
    . "$R2R_ROOT/lib/$f.sh"
  done
}

# Resolve a path from the config relative to the config file's directory.
cfg_path() {
  case $1 in
    /*) printf '%s\n' "$1" ;;
    '') printf '\n' ;;
    *)  printf '%s/%s\n' "$R2R_CONFIG_DIR" "$1" ;;
  esac
}

require_vars() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "config variable $v is not set"
  done
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

valid_mac()  { printf '%s' "$1" | grep -Eqi '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
valid_cidr4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; }

# Network address of an IPv4 CIDR: 192.0.2.10/24 -> 192.0.2.0/24
cidr4_network() {
  local ip=${1%/*} len=${1#*/} a b c d n mask
  IFS=. read -r a b c d <<EOF
$ip
EOF
  n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
  n=$(( n & mask ))
  printf '%d.%d.%d.%d/%d\n' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
    $(( (n >> 8) & 255 )) $(( n & 255 )) "$len"
}

# YAML single-quoted scalar.
yaml_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# Render a template.
#   @NAME@          -> value of environment variable R2R_T_NAME (must be exported)
#   a line @@NAME@@ -> contents of file <blockdir>/NAME (already indented)
# Values are inserted literally (no sed escaping issues); unknown names fail.
r2r_render() {
  local tmpl=$1 out=$2 bdir=$3
  awk -v bdir="$bdir" '
    /^[ \t]*@@[A-Z0-9_]+@@[ \t]*$/ {
      name = $0; gsub(/[ \t@]/, "", name); f = bdir "/" name
      if ((getline l < f) <= 0) { print "missing block " name > "/dev/stderr"; err = 1; next }
      print l; while ((getline l < f) > 0) print l; close(f); next
    }
    {
      line = $0; out = ""
      while (match(line, /@[A-Z0-9_]+@/)) {
        key = "R2R_T_" substr(line, RSTART + 1, RLENGTH - 2)
        if (!(key in ENVIRON)) { print "unset placeholder " key > "/dev/stderr"; err = 1 }
        out = out substr(line, 1, RSTART - 1) ENVIRON[key]
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
    END { exit err }' "$tmpl" > "$out" || die "rendering $tmpl failed"
}

# x86-64 microarchitecture level check (RHEL 10 needs v3).
x86_64_v3_supported() {
  local ld=/usr/lib64/ld-linux-x86-64.so.2
  [ -x "$ld" ] || return 2
  "$ld" --help 2>/dev/null | grep -q 'x86-64-v3 (supported'
}
