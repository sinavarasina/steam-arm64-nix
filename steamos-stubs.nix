# Helpers and stand-ins for the SteamOS scripts the client runs in Deck mode
# (-steamos3). Valve's client calls them by path under /usr/bin and
# /usr/bin/steamos-polkit-helpers. Timezone and hostname changes are forwarded
# over the system D-Bus to systemd-timedated and systemd-hostnamed on the host
# (reachable both directly and through muvm's system bus bridge), branch
# queries read the active Steam client channel dynamically, and OS-update or
# hardware-sysfs helpers answer "nothing to do" on a NixOS host.
{ linkFarm, writeShellScript }:
let
  noop = name: writeShellScript name "exit 0";

  # Exit 7 is SteamOS's "no update available"; the flag is a capability probe.
  steamosUpdate = writeShellScript "steamos-update" ''
    case "$*" in
      *--supports-duplicate-detection*) exit 0 ;;
    esac
    exit 7
  '';

  # Steam's CSystemManager queries -l (available OS branches: rel, rc, beta,
  # bc, preview, pc, main) and -c (current branch), and invokes the polkit
  # helper with a branch name when the user switches channels in Settings.
  # Map the active channel dynamically from the saved state or package/beta.
  steamosSelectBranch = writeShellScript "steamos-select-branch" ''
    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}"
    state_file="$state_dir/steamos-branch"
    steam_root="''${STEAM_ARM64_ROOT:-''${XDG_DATA_HOME:-$HOME/.local/share}/Steam}"
    case "''${1:-}" in
      -l)
        printf '%s\n' rel beta preview
        ;;
      -c)
        if [ -s "$state_file" ]; then
          head -n 1 "$state_file"
        elif [ -s "$steam_root/package/beta" ]; then
          case "$(head -n 1 "$steam_root/package/beta")" in
            *beta*) echo beta ;;
            *) echo rel ;;
          esac
        else
          echo rel
        fi
        ;;
      rel | rc | beta | bc | preview | pc | main)
        mkdir -p -- "$state_dir"
        printf '%s\n' "$1" >"$state_file"
        ;;
      stable)
        mkdir -p -- "$state_dir"
        printf 'rel\n' >"$state_file"
        ;;
    esac
  '';

  # timedatectl set-timezone talks to org.freedesktop.timedate1 on the system
  # bus. Calling the D-Bus method directly works both on the host and inside
  # the muvm guest over the bridged system bus, without needing systemd in FHS.
  steamosSetTimezone = writeShellScript "steamos-set-timezone" ''
    if [ -z "''${1:-}" ]; then
      echo "usage: steamos-set-timezone <timezone>" >&2
      exit 1
    fi
    exec dbus-send --system --print-reply \
      --dest=org.freedesktop.timedate1 \
      /org/freedesktop/timedate1 \
      org.freedesktop.timedate1.SetTimezone \
      "string:$1" boolean:true >/dev/null
  '';

  # hostnamectl set-hostname talks to org.freedesktop.hostname1 on the system
  # bus. SetStaticHostname is best-effort because /etc/hostname on NixOS may be
  # a read-only store symlink, while SetHostname updates the transient hostname.
  steamosSetHostname = writeShellScript "steamos-set-hostname" ''
    if [ -z "''${1:-}" ]; then
      echo "usage: steamos-set-hostname <hostname>" >&2
      exit 1
    fi
    dbus-send --system --print-reply \
      --dest=org.freedesktop.hostname1 \
      /org/freedesktop/hostname1 \
      org.freedesktop.hostname1.SetStaticHostname \
      "string:$1" boolean:true >/dev/null 2>&1 || true
    exec dbus-send --system --print-reply \
      --dest=org.freedesktop.hostname1 \
      /org/freedesktop/hostname1 \
      org.freedesktop.hostname1.SetHostname \
      "string:$1" boolean:true >/dev/null
  '';
in
linkFarm "steamos-stubs" {
  "bin/steamos-update" = steamosUpdate;
  "bin/steamos-polkit-helpers/steamos-update" = steamosUpdate;

  "bin/steamos-select-branch" = steamosSelectBranch;
  "bin/steamos-polkit-helpers/steamos-select-branch" = steamosSelectBranch;

  # The client may ask for its Wi-Fi backend to become iwd. The host keeps the
  # backend it has (NetworkManager), so accept and change nothing.
  "bin/steamos-wifi-set-backend" = noop "steamos-wifi-set-backend";

  # Deck mode writes AMD/Jupiter brightness, TDP and fan values to sysfs
  # through steamos-priv-write; those sysfs paths do not exist on ARM64 hosts.
  "bin/steamos-polkit-helpers/steamos-priv-write" = noop "steamos-priv-write";

  "bin/steamos-set-timezone" = steamosSetTimezone;
  "bin/steamos-polkit-helpers/steamos-set-timezone" = steamosSetTimezone;

  "bin/steamos-set-hostname" = steamosSetHostname;
  "bin/steamos-polkit-helpers/steamos-set-hostname" = steamosSetHostname;
}
