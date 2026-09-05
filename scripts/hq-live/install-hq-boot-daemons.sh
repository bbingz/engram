#!/bin/bash
# Run as root. Installs HQ boot LaunchDaemons; does not SIGKILL/SIGTERM
# the already-running gui-domain helpers. A just-bootstrapped job may
# exit 0 immediately because :8787 / the writer lock is already held.
set -euo pipefail
script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
src="$script_dir"
installer="$script_dir/install-launchd-plist"
[[ -x "$installer" ]] || {
  echo "missing executable ${installer}" >&2
  exit 1
}
files=(com.engram.remote-server.boot.plist com.engram.service.boot.plist)
labels=(com.engram.remote-server.boot com.engram.service.boot)
for index in 0 1; do
  f="${files[$index]}"
  label="${labels[$index]}"
  if [[ ! -e "${src}/${f}" && ! -L "${src}/${f}" ]]; then
    echo "missing ${src}/${f}" >&2
    exit 1
  fi
  "$installer" --validate "${src}/${f}" "$label"
done
if [[ "${1:-}" == "--validate-only" ]]; then
  [[ "$#" -eq 1 ]] || { echo "usage: $0 [--validate-only]" >&2; exit 2; }
  echo "validated com.engram.remote-server.boot com.engram.service.boot"
  exit 0
fi
[[ "$#" -eq 0 ]] || { echo "usage: $0 [--validate-only]" >&2; exit 2; }
if [[ "$(id -u)" -ne 0 ]]; then
  echo "must run as root" >&2
  exit 1
fi
root_gid="$(/usr/bin/id -g root)"
for index in 0 1; do
  f="${files[$index]}"
  label="${labels[$index]}"
  "$installer" \
    "${src}/${f}" "/Library/LaunchDaemons/${f}" 0 "$root_gid" 0644 "$label"
done
for label in "${labels[@]}"; do
  if /bin/launchctl print "system/${label}" >/dev/null 2>&1; then
    /bin/launchctl bootout "system/${label}" >/dev/null 2>&1 || true
  fi
  /bin/launchctl bootstrap system "/Library/LaunchDaemons/${label}.plist"
done
echo "installed system/com.engram.remote-server.boot system/com.engram.service.boot"
