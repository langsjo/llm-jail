{ config, lib, pkgs, nixpkgs-rolling, ... }:

let
  addr = import ../lib/addresses.nix;

  # Read-only boot-time share (store lower layer, envfs). Caching is chosen
  # host-side by virtiofsd's --cache.
  roBootShare = device: {
    inherit device;
    fsType = "virtiofs";
    # A virtiofs mount has no device unit to wait for, and it fails if udev has
    # not bound the virtio device yet, which drops the initrd into emergency mode.
    options = [ "x-systemd.after=systemd-udev-settle.service" "ro" ];
    neededForBoot = true;
  };
in
{
  options.llmjail = {
    toolBinary = lib.mkOption {
      type = lib.types.either lib.types.str lib.types.package;
      description = "Path to the tool binary to exec in the guest (string or derivation)";
    };
    dangerousFlag = lib.mkOption {
      type = lib.types.str;
      description = "CLI flag to pass when --dangerous is enabled";
    };
    extraAllowedDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Domains added to the tool's default network whitelist by optional guest modules (read by mkRunner)";
    };
    launcher = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Script the runner executes over ssh to start the tool";
      default = pkgs.writeShellScript "launch-tool" ''
        # Source NixOS's global environment before modifying env vars. Must be sourced before
        # `set -u` since some variables such as `XDG_STATE_HOME` may not be set.
        source /etc/set-environment
        # The runner's env file (`export NAME=<%q-quoted value>` lines). Sourced after
        # set-environment so the host SHELL and the other forwarded values win.
        # shellcheck disable=SC1091
        source /llmjail-env/env

        set -euo pipefail
        # Add host packages to PATH if available (NixOS host)
        if [ -d /host-user-sw/bin ]; then
          export PATH="$PATH:/host-user-sw/bin"
        fi
        if [ -d /host-sw/bin ]; then
          export PATH="$PATH:/host-sw/bin"
        fi

        # cd into the workspace before sourcing dev-env: devenv's shellHook
        # can do its own relative-path checks (e.g. per-language module
        # checks like `./foo/package.json`) that assume cwd is the project
        # root, not wherever the ssh session started (the home directory,
        # and the workspace path differs under --same-path).
        cd "''${WORKSPACE_DIR:-/workspace}"

        if [ -f /llmjail-env/dev-env ]; then
          # dev-env is `nix print-dev-env` or `devenv direnv-export`
          # output - a bash script setting PATH, etc. Neither is written
          # to tolerate nounset/errexit, so relax strict mode just for
          # the source.
          set +euo pipefail
          # shellcheck disable=SC1091
          source /llmjail-env/dev-env
          set -euo pipefail
        fi

        ARGS=()
        if [ "''${LLMJAIL_DANGEROUS:-0}" = "1" ]; then
          ARGS+=(${config.llmjail.dangerousFlag})
        fi

        # Read null-separated tool args preserving argument boundaries
        if [ -s /llmjail-env/tool-args ]; then
          while IFS= read -r -d "" arg; do
            ARGS+=("$arg")
          done < /llmjail-env/tool-args
        fi

        exec ${config.llmjail.toolBinary} "''${ARGS[@]}"
      '';
    };
  };

  config = {
    boot.loader.grub.enable = false;
    boot.kernelParams = [
      (if pkgs.stdenv.hostPlatform.isAarch64 then "console=ttyAMA0" else "console=ttyS1")
      # A guest panic reboots at once; -no-reboot turns that into a QEMU exit, so the
      # runner's ssh master fails instead of hanging.
      "panic=-1"
      # No systemd-ssh-generator sockets (it would add a guest-local AF_UNIX sshd socket).
      "systemd.ssh_auto=no"
    ];
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "virtio_rng"
      "virtiofs"
    ];
    # Force-load overlay in initrd: availableKernelModules only allows
    # autoload, but the systemd-initrd path doesn't always trigger it for
    # `mount -t overlay`, so make it explicit.
    boot.initrd.kernelModules = [ "overlay" ];
    # nf_tables for rootless Docker, whose user namespace cannot load modules.
    boot.kernelModules = [ "nf_tables" "virtio_console" ];

    # roBootShare mounts are ordered after this unit, which the initrd neither
    # ships nor starts by default. Pulled in here rather than with
    # x-systemd.requires, which would also apply to the same mounts in stage 2.
    boot.initrd.systemd.additionalUpstreamUnits = [ "systemd-udev-settle.service" ];
    boot.initrd.systemd.services.systemd-udev-settle.wantedBy = [ "initrd-fs.target" ];

    boot.initrd.supportedFilesystems = [ "ext4" ];

    # The root filesystem is chosen at runtime by the runner, which appends
    # `root=tmpfs` or, under --disk, `root=/dev/vda` to the kernel cmdline
    # for systemd's initrd fstab-generator. So there is no fileSystems."/",
    # and NixOS must not add its own `root=` to kernel-params.
    boot.initrd.systemd.root = null;

    # Set up the /nix/store overlay in initrd. Runs after the host store
    # mount (RequiresMountsFor, which also orders it after the root at
    # /sysroot) and before initrd-fs.target so stage 2 sees the overlay. The
    # store mount is used directly as the overlay lower layer - overlayfs
    # does not reliably cross submount boundaries, so the lower must be the
    # mounted filesystem itself. The upper layer lives on the root
    # filesystem, outside the /nix/store the overlay covers.
    boot.initrd.systemd.services.llmjail-store-overlay = {
      description = "Set up /nix/store overlay";
      # Pulled in by initrd-fs.target AND by initrd-find-nixos-closure.service
      # (the latter races us in 26.05+ and inspects /sysroot/nix/store before
      # the overlay exists - so we must complete before it starts).
      wantedBy = [ "initrd-fs.target" "initrd-find-nixos-closure.service" ];
      before = [ "initrd-fs.target" "initrd-find-nixos-closure.service" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = "/sysroot/.nix-lower/store";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Mirror stdout/stderr to guest.log so failures
        # are visible before we have journalctl. Drop after stabilizing.
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      script = ''
        set -eu

        mkdir -p \
          /sysroot/.nix-upper/store \
          /sysroot/.nix-upper/work \
          /sysroot/nix/store
        mount -t overlay overlay /sysroot/nix/store \
          -o "lowerdir=/sysroot/.nix-lower/store,upperdir=/sysroot/.nix-upper/store,workdir=/sysroot/.nix-upper/work"
      '';
    };

    # Host nix store read-only (lower layer for the /nix/store overlay above).
    # Mounted outside /nix so it isn't hidden when the overlay covers /nix/store.
    fileSystems."/.nix-lower/store" = roBootShare "nix-store";

    # The /nix/store overlay is set up by the llmjail-store-overlay initrd
    # service (above) which orders itself after the lower layer is mounted.
    # /llmjail-env: small config files plus the host nix db snapshot.
    # Read-only and immutable during the run, so it is cached aggressively.
    fileSystems."/llmjail-env" = roBootShare "envfs";

    # The NIC is a tap in a per-run network namespace on the host, which
    # holds the network filter and the DNS server (dnsmasq, answering only
    # allowed names; lib/net.nix). Nothing in the guest enforces anything:
    # changing this config, even as root, reaches nothing more.
    networking.useDHCP = false;
    networking.nameservers = [ addr.gateway ];
    networking.firewall.enable = false;

    # nixos-26.05 + systemd-networkd auto-enables resolved, which would put its
    # own stub in front of the host's dnsmasq. Keep glibc on /etc/resolv.conf.
    services.resolved.enable = false;

    # Gives interface name "eth0"
    networking.usePredictableInterfaceNames = false;
    systemd.network = {
      enable = true;
      networks."eth0" = {
        matchConfig.Name = "eth0";
        address = [ "${addr.guest}/${toString addr.prefixLength}" ];
        gateway = [ addr.gateway ];
      };
      wait-online.enable = true;
    };

    users.users.user = {
      isNormalUser = true;
      uid = 1000;
      home = "/home/user";
      shell = pkgs.bash;
      extraGroups = [ "systemd-journal" ];
    };

    users.mutableUsers = true;
    systemd.services.llmjail-set-user-uid = {
      wantedBy = [ "llmjail-mounts.service" ];
      before = [ "llmjail-mounts.service" ];
      script = ''
        USER_UID=""
        for arg in $(cat /proc/cmdline); do
          case "$arg" in
            llmjail.user_uid=*) USER_UID="''${arg#llmjail.user_uid=}" ;;
          esac
        done
        if [[ -n "$USER_UID" && "$USER_UID" -ge 1000 ]] && ! ${pkgs.getent}/bin/getent passwd "$USER_UID"; then
          ${pkgs.shadow}/bin/usermod -u "$USER_UID" user
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
      };
    };

    # Parses kernel cmdline for llmjail.mounts=tag0:/path:rw,tag1:/path:ro,...
    # and mounts each entry via virtiofs. Masks and read-only git files are
    # applied by the host before virtiofsd starts (lib/share.nix), so they
    # hold whatever happens in here.
    systemd.services.llmjail-mounts = {
      description = "Mount llmjail host shares from kernel cmdline";
      wantedBy = [ "multi-user.target" ];
      before = [ "llmjail-ready.target" ];
      after = [ "local-fs.target" ];
      # A share that could not be mounted must not leave a session without its
      # workspace; poweroff-force still syncs.
      unitConfig.FailureAction = "poweroff-force";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        MOUNTS=""
        LOGIN_USER=user
        for arg in $(cat /proc/cmdline); do
          case "$arg" in
            llmjail.mounts=*) MOUNTS="''${arg#llmjail.mounts=}" ;;
            llmjail.root=1) LOGIN_USER=root ;;
          esac
        done

        # Per-run ssh key from the runner, for the account the session runs as
        # (root only with --root; without a key root cannot log in). Installed
        # before the early exit below so it also happens without mounts
        # (nixosTest nodes). Root-owned so sshd's StrictModes passes and the
        # agent cannot edit it.
        if [ -f /llmjail-env/authorized_keys ]; then
          ${pkgs.coreutils}/bin/install -D -m 0444 -o root -g root \
            /llmjail-env/authorized_keys "/etc/ssh/authorized_keys.d/$LOGIN_USER"
        fi

        if [ -z "$MOUNTS" ]; then
          echo "No llmjail mounts specified."
          exit 0
        fi

        IFS=',' read -ra ENTRIES <<< "$MOUNTS"
        for entry in "''${ENTRIES[@]}"; do
          IFS=':' read -r tag mpath mode <<< "$entry"

          echo "Mounting $tag -> $mpath ($mode)"
          ${pkgs.coreutils}/bin/mkdir -p "$mpath"

          # Caching is set host-side per share (virtiofsd --cache)
          OPTS="rw"
          if [ "$mode" = "ro" ] || [ "$mode" = "ro-nocache" ]; then
            OPTS="ro"
          fi
          ${pkgs.util-linux}/bin/mount -t virtiofs "$tag" "$mpath" -o "$OPTS"

          # Fix ownership for paths under /home/user
          case "$mpath" in
            /home/user|/home/user/*)
              ${pkgs.coreutils}/bin/chown user:users "$mpath" 2>/dev/null || true
              ;;
          esac
        done

        # Copy dotfiles provided via envfs (can't mount individual files via
        # virtiofs). Currently just .gitconfig, placed there by mkRunner.
        for src in /llmjail-env/.*; do
          [ -f "$src" ] || continue
          name="''${src##*/}"
          ${pkgs.coreutils}/bin/cp "$src" "/home/user/$name"
          ${pkgs.coreutils}/bin/chown user:users "/home/user/$name"
        done
      '';
    };

    environment.systemPackages = with pkgs; [
      git
      nodejs
      openssh
      coreutils
      bash
      curl
      findutils
      gnugrep
      gnused
      gawk
      diffutils
    ];

    # The tool runs in an ssh session over the llmjail.ssh virtserialport.
    # The NixOS module supplies sshd_config, PAM, the privsep user and the
    # host key; its own listening sshd.service never starts, so nothing in
    # the guest listens for sshd on any network or vsock address.
    services.openssh = {
      enable = true;
      openFirewall = false;
      authorizedKeysInHomedir = false;
      hostKeys = [ { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; } ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        # Key only, and llmjail-mounts installs one for root only with --root
        # (llmjail.root=1).
        PermitRootLogin = "prohibit-password";
        AllowUsers = [ "user" "root" ];
        PrintMotd = false;
        PrintLastLog = false;
        PermitUserRC = false;
      };
    };
    systemd.services.sshd.wantedBy = lib.mkForce [ ];

    # Root-only port; the systemd tag creates the .device unit llmjail-sshd orders after.
    services.udev.extraRules = ''
      KERNEL=="vport*", ATTR{name}=="llmjail.ssh", MODE="0600", OWNER="root", TAG+="systemd"
    '';

    systemd.targets.llmjail-ready = {
      description = "llmjail guest setup finished";
      wantedBy = [ "multi-user.target" ];
      requires = [ "llmjail-mounts.service" ];
      after = [ "llmjail-mounts.service" ];
    };

    # One sshd -i serving the single connection the runner's ssh master opens.
    # When it exits (master closed or connection dropped) the guest powers off.
    systemd.services.llmjail-sshd = {
      description = "llmjail sshd on the llmjail.ssh virtio port";
      wantedBy = [ "multi-user.target" ];
      requires = [ "llmjail-ready.target" ];
      wants = [ "sshd-keygen.service" "dev-virtio\\x2dports-llmjail.ssh.device" ];
      after = [ "llmjail-ready.target" "sshd-keygen.service" "dev-virtio\\x2dports-llmjail.ssh.device" ];
      path = [ config.services.openssh.package ];
      environment.LD_LIBRARY_PATH = config.system.nssModules.path;
      # Backstop: if stdio setup on the port fails, ExecStopPost cannot run either.
      unitConfig.FailureAction = "poweroff";
      serviceConfig = {
        ExecStart = "${config.services.openssh.package}/bin/sshd -i -f /etc/ssh/sshd_config";
        ExecStopPost = "${pkgs.systemd}/bin/systemctl poweroff --no-block";
        # Same path for both: systemd opens the port once, read-write.
        StandardInput = "file:/dev/virtio-ports/llmjail.ssh";
        StandardOutput = "file:/dev/virtio-ports/llmjail.ssh";
        StandardError = "journal";
      };
    };

    # Bounded stop times so a clean poweroff (services stopped, shares synced)
    # fits in the runner's 15 s wait. user@ bounds the whole user manager,
    # rootless dockerd included. MinimumUptimeSec defaults to 15 s since
    # systemd 256; integer 0 to match test-instrumentation.nix (merge needs equal values).
    systemd.settings.Manager = {
      DefaultTimeoutStopSec = "5s";
      MinimumUptimeSec = 0;
    };
    systemd.services."user@".serviceConfig.TimeoutStopSec = "5s";

    # Journal to the serial port behind guest.log. mkDefault: nixosTest's
    # instrumentation sets these too, and the option only merges equal values.
    services.journald.settings.Journal = {
      ForwardToConsole = true;
      MaxLevelConsole = lib.mkDefault "info";
      TTYPath = lib.mkDefault (if pkgs.stdenv.hostPlatform.isAarch64 then "/dev/ttyAMA0" else "/dev/ttyS1");
    };

    # Register the host store's paths in the guest nix db before the
    # nix-daemon starts. Preferred source is a snapshot of the host's
    # /nix/var/nix/db/db.sqlite (llmjail.nix_db_snapshot, taken by the
    # runner via `sqlite3 VACUUM INTO` and shipped through the envfs share):
    # installing the file takes milliseconds, vs minutes for --load-db of
    # a big store. Falls back to the toplevel closure registration dump
    # (llmjail.nix_db_dump) when no snapshot is available. Mostly copied
    # from nixpkgs/nixos/modules/virtualisation/qemu-vm.nix.
    systemd.services.register-nix-paths = {
      unitConfig.DefaultDependencies = false;
      wantedBy = [ "sysinit.target" ];

      before = [
        "sysinit.target"
        "shutdown.target"
        "nix-daemon.socket"
        "nix-daemon.service"
      ];
      after = [
        "local-fs.target"
      ];
      conflicts = [
        "shutdown.target"
      ];
      restartIfChanged = false;
      script = ''
        NIX_DB_SNAPSHOT=""
        NIX_DB_DUMP=""
        for arg in $(cat /proc/cmdline); do
          case "$arg" in
            llmjail.nix_db_snapshot=*) NIX_DB_SNAPSHOT="''${arg#llmjail.nix_db_snapshot=}" ;;
            llmjail.nix_db_dump=*) NIX_DB_DUMP="''${arg#llmjail.nix_db_dump=}" ;;
          esac
        done

        if [[ -n "$NIX_DB_SNAPSHOT" ]] && [[ -s "$NIX_DB_SNAPSHOT" ]]; then
          echo "Installing host nix db snapshot ($NIX_DB_SNAPSHOT)"
          ${pkgs.coreutils}/bin/mkdir -p /nix/var/nix/db
          # Drop any WAL state; the snapshot is a clean standalone db.
          ${pkgs.coreutils}/bin/rm -f /nix/var/nix/db/db.sqlite-wal /nix/var/nix/db/db.sqlite-shm
          ${pkgs.coreutils}/bin/install -m 0644 "$NIX_DB_SNAPSHOT" /nix/var/nix/db/db.sqlite
        elif [[ -n "$NIX_DB_DUMP" ]]; then
          echo "Loading closure nix db dump ($NIX_DB_DUMP)"
          ${lib.getExe' config.nix.package "nix-store"} --load-db < "$NIX_DB_DUMP"
        else
          echo "<4> No Nix db snapshot or dump specified, not initializing Nix db"
          exit 1
        fi
      '';
    };

    systemd.services."serial-getty@ttyAMA0".enable = false;
    systemd.services."serial-getty@ttyS0".enable = false;
    systemd.services."serial-getty@ttyS1".enable = false;
    systemd.services."getty@tty1".enable = false;

    # No display (QEMU runs with -nodefaults), so no keymap or font to set up.
    # systemd-vconsole-setup only started once udev had worked through the
    # console devices, and sysinit.target, which everything after waits on,
    # waited for it.
    console.enable = false;
    # The root filesystem is new on every boot, so these ran every time for
    # nothing: the journal message catalog rebuild, and login records.
    systemd.services.systemd-journal-catalog-update.enable = false;
    systemd.services.systemd-update-utmp.enable = false;
    systemd.services.systemd-update-utmp-runlevel.enable = false;

    documentation.enable = false;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    nix.settings.sandbox = false;

    # Pin nixpkgs within the VM.
    nix.registry.nixpkgs.to = {
      type = "path";
      path = nixpkgs-rolling;
    };
    nix.nixPath = [ "nixpkgs=${nixpkgs-rolling}" ];

    system.stateVersion = "24.11";
  };
}
