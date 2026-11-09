{
  pkgs,
  name,
  guest,
  toolDefaults,
  flags,
}:

let
  inherit (pkgs) lib;
  toplevel = guest.config.system.build.toplevel;
  toplevelDbDump = pkgs.closureInfo { rootPaths = [ toplevel ]; };
  qemuPkg = pkgs.qemu_kvm;
  arch = if pkgs.stdenv.hostPlatform.isx86_64 then "x86_64" else "aarch64";
  allowedDomains = toolDefaults.allowedDomains ++ guest.config.llmjail.extraAllowedDomains;
  share = import ./share.nix { inherit pkgs; };
  net = import ./net.nix { inherit pkgs; };
in
pkgs.writeShellApplication {
  name = "llm-jail-${name}";
  runtimeInputs = [
    qemuPkg
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.util-linux
    pkgs.nix
    pkgs.e2fsprogs
    pkgs.openssh
    pkgs.socat
    pkgs.sqlite
    pkgs.virtiofsd
  ]
  ++ (lib.optional (flags ? devenv) pkgs.devenv);
  # The cleanup_* functions are only called indirectly, through CLEANUP_FUNCS
  # and the EXIT trap, which shellcheck cannot follow.
  excludeShellChecks = [ "SC2329" ];
  text = ''
    set -euo pipefail

    MEM="${toString toolDefaults.mem}"
    VCPU="${toString toolDefaults.vcpu}"
    DANGEROUS=0
    ROOT=0
    NIX_ENV=0
    DEVENV=0
    IMMUTABLE=0
    SAME_PATH=0
    LLMJAIL_TMPDIR=''${TMPDIR:-/tmp}
    DISK_SIZE=0
    NET_FILTER=1
    EXTRA_DOMAINS=()
    EXTRA_MOUNTS=()
    MASK_PATTERNS=()
    TOOL_ARGS=()

    PROFILE="''${LLMJAIL_PROFILE:-default}"
    STATE_DIR="''${LLMJAIL_STATE_DIR:-}"
    if [ -z "$STATE_DIR" ] && [ -n "''${LLMJAIL_CONFIG_DIR:-}" ]; then
      echo "WARNING: LLMJAIL_CONFIG_DIR is deprecated; use LLMJAIL_STATE_DIR. LLMJAIL_STATE_DIR will be mounted as read-write" >&2
      STATE_DIR="$LLMJAIL_CONFIG_DIR"
    fi

    usage() {
      cat <<'USAGE'
    Usage: llm-jail-${name} [options] [-- tool-args...]

    Arguments in ./.llmjailrc, once approved, are applied before these, so the
    command line wins. Approvals are kept in ~/.config/llm-jail/approved-rc.

    Options:
      --dangerous           Enable the tool's dangerous / unattended mode
      --root                Run the tool (and inspection shells) as root in the VM.
                            The network filter, masks and protected git files are
                            enforced on the host, so root in the VM cannot lift them.
      --profile NAME        State profile, a subdir of --state-dir/<tool> (default: default)
      --state-dir PATH      Jail state root dir (default: ~/.config/llm-jail)
      --immutable           Mount workspace as read-only instead of read-write
      --same-path           Mount workspace at its host path instead of /workspace
                             (lets tools like 'claude --resume' match sessions
                             started outside the sandbox)
      --tmpdir PATH         Directory to use for runtime data (default: ''${TMPDIR:-/tmp})
      --mount HOSTPATH[:GUESTPATH]
                             Extra read-write mount (repeatable). GUESTPATH
                             defaults to HOSTPATH if omitted.
      --ro-mount HOSTPATH[:GUESTPATH]
                             Extra read-only mount (repeatable). GUESTPATH
                             defaults to HOSTPATH if omitted.
      --mask GLOB           Mask paths matching GLOB in workspace/mounts (repeatable).
                            GLOB with '/' uses -path "<root>/GLOB" (matches across
                            subdirs, e.g. 'a/*' also hits 'a/b/c'); else -name GLOB.
                            Matched paths appear empty and read-only; the name stays
                            visible, only the contents are hidden. Applied on the host
                            at startup: paths created later, symlinks, other hard
                            links and git history (git show HEAD:FILE) are not masked.
      --nix-env             Capture nix develop environment from workspace flake
      --devenv              Capture devenv.sh shell environment from workspace
      --disk SIZE           Use an ext4 disk (SIZE in GB) as the root filesystem
                            instead of RAM
      --allow-domain DOMAIN Add domain to network whitelist (repeatable)
      --no-net-filter       Disable network filtering (unrestricted access)
      --mem SIZE            Memory in MB (default: ${toString toolDefaults.mem})
      --vcpu COUNT          vCPUs (default: ${toString toolDefaults.vcpu})
      --norc                Ignore ./.llmjailrc
      -h, --help            Show this help

    Press Enter ~ . to end the session (the VM shuts down). The runner
    prints an ssh command for opening inspection shells in the jail.
    USAGE
      exit 0
    }

    CLEANUP_FUNCS=()
    cleanup() {
      local status=$?
      local i

      for (( i=''${#CLEANUP_FUNCS[@]}-1; i >= 0; i-- )); do
        "''${CLEANUP_FUNCS[i]}" || true
      done

      exit "$status"
    }
    trap cleanup EXIT

    # Called once per argument source, so a `--` ends only that source's runner
    # flags: later sources still parse theirs, and tool args accumulate in order.
    parse_args() {
      while [ $# -gt 0 ]; do
        case "$1" in
          --dangerous)   DANGEROUS=1; shift ;;
          --root)        ROOT=1; shift ;;
          --nix-env)     NIX_ENV=1; shift ;;
          --devenv)      DEVENV=1; shift ;;
          --dev-env|--dev-env=*)
                         echo "ERROR: --dev-env has been renamed to --nix-env." >&2
                         exit 1 ;;
          --profile)     PROFILE="$2"; shift 2 ;;
          --state-dir)   STATE_DIR="$2"; shift 2 ;;
          --config-dir|--config-dir=*)
                         echo "ERROR: --config-dir has been renamed to --state-dir and will be mounted as read-write." >&2
                         exit 1 ;;
          --mount)       EXTRA_MOUNTS+=("$2:rw"); shift 2 ;;
          --ro-mount)    EXTRA_MOUNTS+=("$2:ro"); shift 2 ;;
          --tmpdir)      LLMJAIL_TMPDIR="$2"; shift 2 ;;
          --immutable)    IMMUTABLE=1; shift ;;
          --same-path)   SAME_PATH=1; shift ;;
          --allow-domain)  EXTRA_DOMAINS+=("$2"); shift 2 ;;
          --no-net-filter) NET_FILTER=0; shift ;;
          --mask)        MASK_PATTERNS+=("$2"); shift 2 ;;
          --disk)        DISK_SIZE="$2"; shift 2 ;;
          --store-disk)  echo "WARNING: --store-disk is deprecated; use --disk" >&2
                         DISK_SIZE="$2"; shift 2 ;;
          --mem)         MEM="$2"; shift 2 ;;
          --vcpu)        VCPU="$2"; shift 2 ;;
          --norc)        shift ;; # acted on below, before any parsing
          -h|--help)     usage ;;
          --)            shift; TOOL_ARGS+=("$@"); break ;;
          *)             echo "Unknown option: $1" >&2; usage ;;
        esac
      done
    }

    # The agent can write to the workspace and a cloned repo can ship this file,
    # and its flags can widen the jail, so it needs approval from the user. Hash,
    # prompt and parsing all use one read of the file, so it
    # cannot change between approval and use.
    RC_ARGS=()
    # shortcut: a flag value spelled "--norc" or "--" is misread here; no real value is.
    NORC=0
    for arg in "$@"; do
      case "$arg" in
        --) break ;;
        --norc) NORC=1 ;;
      esac
    done
    if [ "$NORC" = 0 ] && [ -f .llmjailrc ]; then
      RC_CONTENT=$(cat .llmjailrc)
      RC_APPROVAL="$(sha256sum <<<"$RC_CONTENT" | cut -d' ' -f1)  $PWD"
      RC_APPROVALS="''${XDG_CONFIG_HOME:-$HOME/.config}/llm-jail/approved-rc"
      if ! grep -Fxqs -- "$RC_APPROVAL" "$RC_APPROVALS"; then
        if [ ! -t 0 ]; then
          echo "ERROR: $PWD/.llmjailrc is new or changed; run from a terminal to approve it, or use --norc" >&2
          exit 1
        fi
        echo "$PWD/.llmjailrc is new or changed. It can widen the jail (--mount, --no-net-filter, ...):" >&2
        # cat -v: control characters must not be able to hide what is approved
        cat -v <<<"$RC_CONTENT" >&2
        read -r -p "Apply it and remember this approval? [y/N] " RC_ANSWER || true
        # Not "continue without it": the file may hold restrictions like --mask.
        if [[ "$RC_ANSWER" != [yY] ]]; then
          echo "ERROR: $PWD/.llmjailrc not approved; use --norc to run without it" >&2
          exit 1
        fi
        mkdir -p "$(dirname "$RC_APPROVALS")"
        touch "$RC_APPROVALS"
        # One approval per directory, so going back to an older rc prompts again.
        RC_APPROVALS_NEW=$(mktemp "$RC_APPROVALS.XXXXXX")
        while IFS= read -r RC_LINE || [ -n "$RC_LINE" ]; do
          if [ "''${RC_LINE#*  }" != "$PWD" ]; then
            printf '%s\n' "$RC_LINE"
          fi
        done < "$RC_APPROVALS" > "$RC_APPROVALS_NEW"
        echo "$RC_APPROVAL" >> "$RC_APPROVALS_NEW"
        mv "$RC_APPROVALS_NEW" "$RC_APPROVALS"
      fi
      # xargs only splits (whitespace, quotes, backslashes); nothing is expanded or run.
      # It would keep a backslash-escaped newline in the arg, so join those lines first.
      mapfile -d "" -t RC_ARGS < <(xargs -r printf '%s\0' <<<"''${RC_CONTENT//$'\\\n'/ }")
      wait $! || { echo "ERROR: could not parse $PWD/.llmjailrc" >&2; exit 1; }
    fi

    parse_args "''${RC_ARGS[@]}"
    parse_args "$@"

    # Jail-private tool state, fully separate from the host tool's own
    # config dir. --state-dir / LLMJAIL_STATE_DIR overrides the default
    # jail state root (~/.config/llm-jail); <tool>/<profile> is appended.
    if [ -z "$STATE_DIR" ]; then
      STATE_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/llm-jail"
    fi
    STATE_DIR="$STATE_DIR/${name}/$PROFILE"

    if [ ! -d "$LLMJAIL_TMPDIR" ]; then
      echo "ERROR: tmpdir '$LLMJAIL_TMPDIR' does not exist" >&2
      exit 1
    fi

    # Paths used in QEMU option strings (comma-separated) and kernel cmdline
    # (space-separated) cannot contain commas, spaces, or colons (mount spec delimiter),
    # nor '%', which ssh expands in ssh_config values.
    validate_path() {
      local path="$1" label="''${2:-path}"
      if [[ "$path" == *,* ]]; then
        echo "ERROR: $label must not contain commas: $path" >&2
        exit 1
      fi
      if [[ "$path" == *\ * ]]; then
        echo "ERROR: $label must not contain spaces: $path" >&2
        exit 1
      fi
      if [[ "$path" == *:* ]]; then
        echo "ERROR: $label must not contain colons: $path" >&2
        exit 1
      fi
      if [[ "$path" == *%* ]]; then
        echo "ERROR: $label must not contain '%': $path" >&2
        exit 1
      fi
    }

    # Unix socket paths are limited to 107 bytes. EXTRA covers bytes a tool
    # appends (ssh adds 17 to the ControlPath while creating it).
    check_socket_path() {
      local path="$1" extra="''${2:-0}"
      if (( ''${#path} + extra > 107 )); then
        echo "ERROR: socket path too long (max 107 bytes): $path; use --tmpdir with a shorter path" >&2
        exit 1
      fi
    }

    # ssh runs ProxyCommand through $SHELL -c; never let the user's shell
    # (fish, nu, or the runner test's probe) run the master's proxy.
    jail_ssh() {
      SHELL=${pkgs.runtimeShell} ${pkgs.openssh}/bin/ssh -F "$RUNDIR/ssh_config" "$@"
    }

    # Printed only when the VM fails to boot or the connection is lost. The
    # guest controls much of this text (its console and journal, the names it
    # looks up), so cat -v keeps it from sending escape sequences to the
    # terminal.
    print_guest_logs() {
      local log
      for log in "$RUNDIR/qemu.log" "$RUNDIR"/virtiofsd-*.log; do
        if [ -s "$log" ]; then
          echo "--- ''${log##*/} ---" >&2
          cat -v "$log" >&2
        fi
      done
      for log in dnsmasq.log guest.log; do
        if [ -f "$RUNDIR/$log" ]; then
          echo "--- $log (last 200 lines) ---" >&2
          tail -n 200 "$RUNDIR/$log" | cat -v >&2
        fi
      done
    }

    validate_path "$LLMJAIL_TMPDIR" "tmpdir"
    validate_path "$(pwd)" "workspace path"
    # Named after the tool and project so it can be found once the printed
    # inspection command has scrolled away.
    PROJECT=''${PWD##*/}
    PROJECT=''${PROJECT:0:8}
    RUNDIR=$(mktemp -d --tmpdir="$LLMJAIL_TMPDIR" "${name}-''${PROJECT//[^A-Za-z0-9._+-]/_}.XXX")

    cleanup_rundir() {
      [ -d "$RUNDIR" ] && rm -rf "$RUNDIR"
    }
    CLEANUP_FUNCS+=(cleanup_rundir)

    # Absolute: $RUNDIR is written into ssh_config and the printed command.
    RUNDIR=$(realpath "$RUNDIR")
    # $RUNDIR goes unquoted into the proxy command (run by $SHELL -c) and ssh_config.
    if [[ ! "$RUNDIR" =~ ^[A-Za-z0-9._/+-]+$ ]]; then
      echo "ERROR: tmpdir path contains characters ssh cannot use: $RUNDIR; use --tmpdir with a plain path" >&2
      exit 1
    fi
    check_socket_path "$RUNDIR/ssh.sock"
    check_socket_path "$RUNDIR/ctl.sock" 17

    # The ssh client and ssh-keygen need the user's passwd entry; nixpkgs-glibc
    # whoami fails in the same case (e.g. sssd without nscd/nsncd).
    USERNAME=$(whoami 2>/dev/null) || {
      echo "ERROR: your user is not resolvable through nixpkgs' glibc (e.g. sssd without nscd/nsncd); the ssh client cannot run" >&2
      exit 1
    }

    # The jail's boundaries live in namespaces on the host (lib/share.nix,
    # lib/net.nix). The test mount also catches Ubuntu's AppArmor, which lets
    # unprivileged user namespaces be created but strips their capabilities.
    if ! unshare --user --map-current-user --keep-caps --mount -- \
         mount -t tmpfs llmjail-check "$RUNDIR" 2>/dev/null; then
      echo "ERROR: unprivileged user namespaces are not available; llm-jail needs them" >&2
      echo "(on Ubuntu 23.10+: sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0)" >&2
      exit 1
    fi
    if [ ! -c /dev/net/tun ]; then
      echo "ERROR: /dev/net/tun is missing; the jail's network needs it" >&2
      exit 1
    fi

    # Only this directory is shared with the guest (envfs, at /llmjail-env).
    SHAREDIR="$RUNDIR/share"
    mkdir "$SHAREDIR"

    WORKSPACE_DIR="/workspace"
    if [[ "$SAME_PATH" -eq 1 ]]; then
      WORKSPACE_DIR="$(pwd)"
    fi
    # Sourced by the guest launcher: every value %q-quoted, so sourcing it
    # exports the variables and never runs host-supplied text as code.
    ENV_FILE="$SHAREDIR/env"
    env_line() {
      printf 'export %s=%q\n' "$1" "$2"
    }
    {
      for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_MAX_OUTPUT_TOKENS OPENAI_API_KEY OPENAI_BASE_URL; do
        if [ -n "''${!var:-}" ]; then
          env_line "$var" "''${!var}"
        fi
      done

      # Forward host shell (resolved through symlinks so the /nix/store path
      # is exposed, which the guest can reach via the store share even
      # though /run/current-system/sw is remapped to /host-sw).
      if [ -n "''${SHELL:-}" ]; then
        RESOLVED_SHELL=$(readlink -f "$SHELL" 2>/dev/null || true)
        if [ -n "$RESOLVED_SHELL" ]; then
          env_line SHELL "$RESOLVED_SHELL"
        fi
      fi

      # Names only from well-formed lines; multi-line values can't inject names.
      while IFS= read -r name; do
        if [[ "$name" =~ ^AWS_[A-Za-z0-9_]*$ ]]; then
          env_line "$name" "''${!name:-}"
        fi
      done < <(env | cut -d= -f1)

      # TERM and the window size travel with ssh's pty request; COLORTERM does not.
      if [ -n "''${COLORTERM:-}" ]; then
        env_line COLORTERM "$COLORTERM"
      fi

      env_line HOME /home/user
      env_line LLMJAIL_DANGEROUS "$DANGEROUS"
      # Relocate the tool's state into the jail-private state mount
      env_line ${toolDefaults.configEnvVar} /home/user/${toolDefaults.configDirName}
      env_line WORKSPACE_DIR "$WORKSPACE_DIR"
    } > "$ENV_FILE"

    # Write tool args as null-separated file to preserve argument boundaries
    if [ ''${#TOOL_ARGS[@]} -gt 0 ]; then
      printf '%s\0' "''${TOOL_ARGS[@]}" > "$SHAREDIR/tool-args"
    else
      : > "$SHAREDIR/tool-args"
    fi

    if [ "$NET_FILTER" = "1" ]; then
      {
        ${builtins.concatStringsSep "\n    " (map (d: "echo \"${d}\"") allowedDomains)}

        # Auto-extract domains from base URL env vars
        for var in ANTHROPIC_BASE_URL OPENAI_BASE_URL; do
          val="''${!var:-}"
          if [ -n "$val" ]; then
            domain="''${val#*://}"
            domain="''${domain%%/*}"
            domain="''${domain%%:*}"
            if [ -n "$domain" ]; then
              echo "$domain"
            fi
          fi
        done

        for d in "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
          echo "$d"
        done
      } | sort -u > "$SHAREDIR/allowed-domains"
    else
      : > "$SHAREDIR/allowed-domains"
    fi

    if [ "$DEVENV" = "1" ] && ! command -v devenv >/dev/null; then
      echo "ERROR: --devenv requires the 'devenv' CLI, which was not found" >&2
      echo "You can add it to the tool by using, for example," >&2
      echo "'packages.x86_64-linux.claude.devenv' instead of 'packages.x86_64-linux.claude'"
      exit 1
    fi

    if [ "$NIX_ENV" = "1" ] && [ "$DEVENV" = "1" ]; then
      echo "ERROR: --nix-env and --devenv are mutually exclusive" >&2
      exit 1
    fi

    if [ "$DEVENV" = "1" ] && [ "$SAME_PATH" != "1" ]; then
      echo "ERROR: --devenv requires --same-path (devenv bakes the workspace's" >&2
      echo "absolute host path into DEVENV_ROOT/DEVENV_DOTFILE/DEVENV_STATE," >&2
      echo "which would otherwise point nowhere once the workspace is mounted" >&2
      echo "at /workspace in the guest)" >&2
      exit 1
    fi

    if [ "$NIX_ENV" = "1" ]; then
      echo "Evaluating nix dev shell..." >&2
      if nix print-dev-env --no-warn-dirty "$(pwd)" > "$SHAREDIR/dev-env" 2>/dev/null; then
        echo "Dev shell environment captured." >&2
      else
        echo "WARNING: nix print-dev-env failed, continuing without dev shell" >&2
        rm -f "$SHAREDIR/dev-env"
      fi
    elif [ "$DEVENV" = "1" ]; then
      echo "Evaluating devenv shell..." >&2
      # `devenv direnv-export` (not `devenv shell`) is the right primitive
      # here: it's the same command devenv's own maintained direnvrc uses
      # to import a devenv shell's environment into an already-running
      # shell (see _nix_import_env in
      # https://github.com/cachix/devenv/blob/main/devenv/direnvrc), so
      # unlike `devenv shell` its output ends cleanly after the shellHook
      # eval with no trailing `exec` to strip - direnv couldn't tolerate
      # having its own process replaced either. It's undocumented/hidden
      # from --help but present and stable enough for devenv to depend on
      # it themselves. _DEVENV_CALLER=direnv matches how direnvrc invokes
      # it; harmless (at most affects logging) if unnecessary.
      #
      # devenv (independent of subcommand - this is its own Rust-side
      # bootstrap, not something baked into the output text) needs
      # XDG_RUNTIME_DIR to be a valid, writable directory or it fails
      # outright ("Failed to create /run/user/<uid>/devenv-<hash>:
      # Permission denied") before producing any output at all - relevant
      # on hosts without a real login session providing /run/user/<uid>.
      # (Unlike `devenv shell`'s rcfile, `direnv-export`'s output only
      # *exports* DEVENV_RUNTIME as a value - it has no accompanying
      # `mkdir -p`/`ln -snf` for it, so there's nothing left to fail when
      # the guest sources this later; this override is purely to let the
      # capture step below succeed on the host.)
      #
      # A dedicated scratch dir is used rather than $RUNDIR: the
      # workspace's own devenv.nix shellHook runs on the host as part of
      # `direnv-export` (same trust model as `nix develop`/
      # `nix print-dev-env` on an untrusted flake), and $SHAREDIR holds
      # allowed-domains/tool-args/env - files the guest
      # treats as the trust boundary for its network allowlist and
      # secrets, staged there before this step runs. A shellHook that
      # discovers $XDG_RUNTIME_DIR could otherwise read or tamper with
      # those files pre-boot.
      DEVENV_RUNTIME_SCRATCH=$(mktemp -d --tmpdir="$LLMJAIL_TMPDIR")
      cleanup_devenv_runtime_scratch() {
        rm -rf "$DEVENV_RUNTIME_SCRATCH"
      }
      CLEANUP_FUNCS+=(cleanup_devenv_runtime_scratch)
      if DEVENV_ERR=$(XDG_RUNTIME_DIR="$DEVENV_RUNTIME_SCRATCH" _DEVENV_CALLER=direnv devenv --no-tui -q direnv-export < /dev/null 2>&1 >"$SHAREDIR/dev-env"); then
        echo "Dev shell environment captured." >&2
      else
        echo "WARNING: devenv shell failed, continuing without dev shell" >&2
        echo "$DEVENV_ERR" >&2
        rm -f "$SHAREDIR/dev-env"
      fi
    fi

    MOUNT_IDX=0
    MOUNT_CMDLINE=""
    SHARE_ARGS=()

    # One virtiofsd per share (it serves a single directory), started as
    # the invoking user - no root needed. --sandbox=namespace pivot_roots
    # into the share inside an unprivileged user namespace, so symlinks
    # cannot escape it. That namespace only maps our own uid/gid, so
    # every guest uid/gid is squashed to ours and host files we don't own
    # (root's /nix/store shows up as the overflow id 65534) are reported to
    # the guest as root.
    HOST_UID=$(id -u)
    HOST_GID=$(id -g)
    VIRTIOFSD_PIDS=()
    cleanup_virtiofsd() {
      kill "''${VIRTIOFSD_PIDS[@]+"''${VIRTIOFSD_PIDS[@]}"}" 2>/dev/null
    }
    CLEANUP_FUNCS+=(cleanup_virtiofsd)

    # vhost-user needs guest RAM in shared memory so virtiofsd can map it
    SHARE_ARGS+=(
      "-object" "memory-backend-memfd,id=mem,size=''${MEM}M,share=on"
      "-machine" "memory-backend=mem"
    )

    # Exports HOSTPATH to the guest under TAG by appending QEMU args to
    # SHARE_ARGS. MODE is rw, ro, ro-nocache, or ro-immutable (contents never
    # change during the run, e.g. envfs). With PROTECT=1 the share is a user
    # directory: --mask applies to it and, if writable, the git files host git
    # executes are read-only (lib/share.nix).
    add_share() {
      local tag="$1" hostpath="$2" mode="$3" protect="''${4:-0}"
      local root
      root=$(realpath "$hostpath")

      local share_args=()
      if [ "$protect" = 1 ]; then
        for p in "''${MASK_PATTERNS[@]+"''${MASK_PATTERNS[@]}"}"; do
          share_args+=("--mask" "$p")
        done
        if [ "$mode" = rw ]; then
          share_args+=("--protect-git")
        fi
      fi

      local sock="$RUNDIR/virtiofsd-$tag.sock"
      local args=(
        "--socket-path=$sock"
        "--shared-dir=$root"
        "--sandbox=namespace"
        "--log-level=error"
        "--translate-uid=squash-guest:0:$HOST_UID:4294967295"
        "--translate-gid=squash-guest:0:$HOST_GID:4294967295"
        "--translate-uid=host:65534:0:1"
        "--translate-gid=host:65534:0:1"
      )
      case "$mode" in
        rw)           ;;
        ro)           args+=("--readonly") ;;
        ro-nocache)   args+=("--readonly" "--cache=never") ;;
        ro-immutable) args+=("--readonly" "--cache=always") ;;
        *)
          echo "ERROR: unknown share mode '$mode' for $hostpath" >&2
          exit 1
          ;;
      esac
      # virtiofsd turns host mount points into guest automounts, which
      # overlayfs rejects in its lower layer (EREMOTE). A Nix build sandbox
      # bind-mounts every store path, so the guest couldn't even find its init.
      if [ "$tag" = "nix-store" ]; then
        args+=("--no-announce-submounts")
      fi
      # Logged to a file, not the terminal: the tool's session owns the tty
      # once QEMU starts. Printed by print_guest_logs, only on failure.
      local log="$RUNDIR/virtiofsd-$tag.log"
      # Own session: a Ctrl-C to the terminal's process group must not reach it.
      # None of these fork, so $! stays virtiofsd's pid.
      setpriv --pdeathsig KILL -- setsid -- \
        ${share}/bin/llmjail-share "''${share_args[@]+"''${share_args[@]}"}" "$root" -- \
        virtiofsd "''${args[@]}" 2>"$log" &
      VIRTIOFSD_PIDS+=($!)

      # QEMU fails outright if the socket isn't there yet
      local i
      for (( i=0; i < 100; i++ )); do
        [ -S "$sock" ] && break
        sleep 0.05
      done
      if [ ! -S "$sock" ]; then
        echo "ERROR: virtiofsd did not start for $hostpath (ensure unprivileged user namespaces are allowed):" >&2
        cat -v "$log" >&2
        exit 1
      fi
      # e.g. a --mask that matched a symlink
      grep '^llmjail-share: ' "$log" >&2 || true

      SHARE_ARGS+=(
        "-chardev" "socket,id=fs-$tag,path=$sock"
        "-device" "vhost-user-fs-pci,queue-size=1024,chardev=fs-$tag,tag=$tag"
      )
    }

    # Not ro-immutable: host nix builds/GC change the store during the run
    add_share nix-store /nix/store ro
    add_share envfs "$SHAREDIR" ro-immutable

    # PROTECT as for add_share.
    add_mount() {
      local hostpath="$1" guestpath="$2" mode="$3" protect="''${4:-0}"
      local tag="mount''${MOUNT_IDX}"
      MOUNT_IDX=$((MOUNT_IDX + 1))

      add_share "$tag" "$hostpath" "$mode" "$protect"

      if [ -n "$MOUNT_CMDLINE" ]; then
        MOUNT_CMDLINE="$MOUNT_CMDLINE,$tag:$guestpath:$mode"
      else
        MOUNT_CMDLINE="$tag:$guestpath:$mode"
      fi
    }

    if [[ "$IMMUTABLE" -eq 1 ]]; then
      add_mount "$(pwd)" "$WORKSPACE_DIR" "ro-nocache" 1
    else
      add_mount "$(pwd)" "$WORKSPACE_DIR" "rw" 1
    fi

    validate_path "$STATE_DIR" "state directory"
    # virtiofsd refuses to share a non-existent path; first run starts empty and
    # the tool goes through its login/onboarding flow inside the jail.
    mkdir -p "$STATE_DIR"
    add_mount "$STATE_DIR" "/home/user/${toolDefaults.configDirName}" "rw"

    # Copy .gitconfig into the envfs share (virtiofs can't mount single files)
    if [ -f "$HOME/.gitconfig" ]; then
      cp "$HOME/.gitconfig" "$SHAREDIR/.gitconfig"
    fi

    # Per-run login key: the private half never leaves $RUNDIR, the public half
    # is installed root-owned in the guest by llmjail-mounts.
    ssh-keygen -q -t ed25519 -N "" -C llm-jail -f "$RUNDIR/id"
    cp "$RUNDIR/id.pub" "$SHAREDIR/authorized_keys"

    # ProxyCommand false: only the master gets the real proxy (on its command
    # line), so any other client joins the master or fails at once instead of
    # opening a second connection that nothing would answer. Host-key checking
    # is off: the key changes every boot and the transport is private to us.
    # The guest controls the server end, so the client offers it nothing beyond
    # the session: no agent, X11 or port forwarding, no local commands.
    LOGIN_USER=user
    if [ "$ROOT" = 1 ]; then
      LOGIN_USER=root
    fi
    cat > "$RUNDIR/ssh_config" <<SSHCONFIG
    Host jail
      User $LOGIN_USER
      ForwardAgent no
      ForwardX11 no
      ClearAllForwardings yes
      PermitLocalCommand no
      ProxyCommand false
      ControlPath $RUNDIR/ctl.sock
      IdentityFile $RUNDIR/id
      IdentitiesOnly yes
      BatchMode yes
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
    SSHCONFIG

    # Snapshot the host nix db into the envfs share so the guest can register the whole host store
    # without replaying rows through `nix-store --load-db` (minutes for big stores). Uses `VACUUM
    # INTO` instead of `.backup`: the backup API opens the WAL source read-only and must take the
    # WAL write lock as a proxy for the read-marks it cannot place in the daemon-owned, non-writable
    # -wal/-shm files; the fcntl write lock then fails with EBADF on the read-only fd and sqlite
    # retries forever (reported as a hang requiring ctrl+c). `VACUUM INTO` reads the source with a
    # plain read transaction, works against the live root-owned nix db, and the output is compact
    # (free pages are dropped). Bounded by `timeout` as a backstop; on failure falls back to the
    # toplevel closure dump.
    NIX_DB_SNAPSHOT=""
    if [ -f /nix/var/nix/db/db.sqlite ]; then
      rm -f "$SHAREDIR/nix-db.sqlite"   # VACUUM INTO refuses an existing output file
      if timeout 60 sqlite3 /nix/var/nix/db/db.sqlite "VACUUM INTO '$SHAREDIR/nix-db.sqlite';" 2>/dev/null; then
        NIX_DB_SNAPSHOT="/llmjail-env/nix-db.sqlite"
      else
        rm -f "$SHAREDIR/nix-db.sqlite" # VACUUM INTO may leave a partial file on failure
        echo "WARNING: could not snapshot host nix db, falling back to closure dump" >&2
      fi
    fi

    # Mount host packages if available (NixOS host)
    if [ -d /run/current-system/sw ]; then
      add_mount "/run/current-system/sw" "/host-sw" "ro"
    fi

    if [ -n "$USERNAME" ] && [ -d "/etc/profiles/per-user/$USERNAME" ]; then
      add_mount "/etc/profiles/per-user/$USERNAME" "/host-user-sw" "ro"
    fi

    for spec in "''${EXTRA_MOUNTS[@]+"''${EXTRA_MOUNTS[@]}"}"; do
      if [ -z "$spec" ]; then continue; fi
      mode="''${spec##*:}"
      paths="''${spec%:*}"
      if [[ "$paths" == *:* ]]; then
        hostpath="''${paths%%:*}"
        guestpath="''${paths#*:}"
      else
        hostpath="$paths"
        guestpath="$paths"
      fi
      if [ ! -d "$hostpath" ]; then
        echo "ERROR: mount path does not exist or is not a directory: $hostpath" >&2
        exit 1
      fi
      validate_path "$hostpath" "mount path"
      validate_path "$guestpath" "mount path"
      add_mount "$hostpath" "$guestpath" "$mode" 1
    done

    KERNEL_PARAMS="$(cat ${toplevel}/kernel-params) init=${toplevel}/init llmjail.mounts=$MOUNT_CMDLINE"

    # The guest has no fileSystems."/"; systemd's initrd fstab-generator
    # mounts the root from these. `rw` because systemd mounts a block-device
    # root read-only otherwise. Without a size option the tmpfs root can grow
    # to half of the guest RAM.
    if [ "$DISK_SIZE" -gt 0 ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS root=/dev/vda rootfstype=ext4 rw"
    else
      KERNEL_PARAMS="$KERNEL_PARAMS root=tmpfs rootflags=mode=0755"
    fi

    # Which account llmjail-mounts installs the login key for
    if [ "$ROOT" = 1 ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.root=1"
    fi

    if USER_UID=''${EUID:-$(id -u)} && [[ -n "$USER_UID" ]]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.user_uid=$USER_UID"
    fi

    if [ -n "$NIX_DB_SNAPSHOT" ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.nix_db_snapshot=$NIX_DB_SNAPSHOT"
    fi

    KERNEL_PARAMS="$KERNEL_PARAMS llmjail.nix_db_dump=${toplevelDbDump}/registration"

    DISK_ARGS=()
    if [ "$DISK_SIZE" -gt 0 ]; then
      truncate -s "''${DISK_SIZE}G" "$RUNDIR/disk.img"
      mkfs.ext4 -q "$RUNDIR/disk.img"
      DISK_ARGS+=("-drive" "file=$RUNDIR/disk.img,format=raw,if=virtio,discard=on")
    fi

    KVM_ARGS=()
    if [ -w /dev/kvm ]; then
      KVM_ARGS+=("-enable-kvm" "-cpu" "host")
    else
      echo "WARNING: /dev/kvm not available, falling back to emulation (slow)" >&2
      KVM_ARGS+=("-cpu" "max")
    fi

    NET_ARGS=(--log "$RUNDIR/dnsmasq.log")
    if [ "$NET_FILTER" = "1" ]; then
      NET_ARGS+=(--allow-domains "$SHAREDIR/allowed-domains")
    else
      NET_ARGS+=(--unfiltered)
    fi

    # The tool's terminal is an ssh session over the llmjail.ssh virtserialport,
    # which throttles instead of dropping data like virtconsole (see AGENTS.md).
    #
    # -display none (not -nographic): -nographic would put a serial port on stdio.
    # Route the kernel console (and the forwarded journal) to guest.log: the first
    # PL011 UART on ARM, or the second 16550A UART on x86.
    # ARM virt defaults to GICv2; max also supports hosts with GICv3-only KVM.
    #
    # QEMU runs in a network namespace whose only way out is the jail's
    # filter (lib/net.nix).
    #
    # Hardening, since the guest (root, with --root) can drive every device:
    # -nodefaults leaves only the devices listed here (no VGA, IDE, floppy,
    # parallel port), -no-user-config ignores host QEMU config files, and
    # -sandbox denies syscalls QEMU never needs once it runs.
    #
    # It runs in its own session so a Ctrl-C to the terminal's process group
    # does not reach it (QEMU installs its own SIGINT handler, overriding the
    # ignore bash gives background jobs). Bash runs without job control, so the
    # job is not a group leader and setsid does not fork. llmjail-net execs
    # pasta, so $! is pasta's pid: pasta exits with QEMU, and QEMU dies with
    # pasta (parent-death signal).
    setpriv --pdeathsig KILL -- setsid -- ${net}/bin/llmjail-net "''${NET_ARGS[@]}" -- \
      qemu-system-${arch} \
      -nodefaults \
      -no-user-config \
      -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
      ${lib.optionalString pkgs.stdenv.hostPlatform.isAarch64 "-machine virt,gic-version=max"} \
      "''${KVM_ARGS[@]}" \
      -m "$MEM" \
      -smp "$VCPU" \
      -kernel ${toplevel}/kernel \
      -initrd ${toplevel}/initrd \
      -append "$KERNEL_PARAMS" \
      -display none \
      -monitor none \
      -device virtio-serial-pci \
      -chardev "socket,id=ssh,path=$RUNDIR/ssh.sock,server=on,wait=off" \
      -device virtserialport,chardev=ssh,name=llmjail.ssh \
      ${lib.optionalString pkgs.stdenv.hostPlatform.isx86_64 "-serial null"} \
      -serial file:"$RUNDIR/guest.log" \
      -no-reboot \
      -device virtio-rng-pci \
      -netdev tap,id=net0,ifname=jail0,script=no,downscript=no,vhost=off \
      -device virtio-net-pci,netdev=net0 \
      "''${SHARE_ARGS[@]}" \
      "''${DISK_ARGS[@]}" \
      </dev/null >"$RUNDIR/qemu.log" 2>&1 &
    VM_PID=$!
    cleanup_vm() {
      kill "$VM_PID" 2>/dev/null
      wait "$VM_PID" 2>/dev/null
    }
    CLEANUP_FUNCS+=(cleanup_vm)

    # Registered after cleanup_vm, so it runs first.
    cleanup_master() {
      jail_ssh -O exit jail 2>/dev/null || true
    }
    CLEANUP_FUNCS+=(cleanup_master)

    # Ctrl-C ends ssh but not the runner, which then prints the logs (boot) or
    # shuts down normally (session). INT only: SIGTERM to the runner alone keeps
    # its default action and the EXIT cleanup kills QEMU.
    trap ':' INT

    echo "Booting VM…" >&2
    # The master connects before the guest has booted, so no guest output is
    # written while no client is connected; its login completing is the
    # readiness signal. socat retries the connect until QEMU binds ssh.sock.
    # ssh prefixes ProxyCommand with `exec` itself; setsid keeps the proxy out of
    # the terminal's process group (ssh forks it before daemonizing).
    proxy="${pkgs.util-linux}/bin/setsid ${pkgs.socat}/bin/socat - UNIX-CONNECT:$RUNDIR/ssh.sock,retry=50,interval=0.1"
    if ! jail_ssh -f -M -N -o "ProxyCommand=$proxy" jail \
         </dev/null >/dev/null 2>"$RUNDIR/ssh-master.log"; then
      echo "VM did not become ready" >&2
      if [ -s "$RUNDIR/ssh-master.log" ]; then
        echo "--- ssh-master.log ---" >&2
        cat -v "$RUNDIR/ssh-master.log" >&2
      fi
      print_guest_logs
      exit 1
    fi

    echo "To open a shell in this jail: ${pkgs.openssh}/bin/ssh -F $RUNDIR/ssh_config jail" >&2

    TTY_FLAG=-T
    if [ -t 0 ] && [ -t 1 ]; then
      TTY_FLAG=-t
    fi
    rc=0
    jail_ssh "$TTY_FLAG" jail ${guest.config.llmjail.launcher} || rc=$?
    trap - INT

    if ! jail_ssh -O check jail 2>/dev/null; then
      echo "lost connection to VM" >&2
      print_guest_logs
    fi
    # Closing the master ends every session; the guest's sshd exits and its
    # unit powers the VM off cleanly.
    jail_ssh -O exit jail 2>/dev/null || true
    for (( i=0; i < 75; i++ )); do
      kill -0 "$VM_PID" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$VM_PID" 2>/dev/null; then
      echo "VM did not power off within 15 s; killing it" >&2
      kill -KILL "$VM_PID" 2>/dev/null || true
    fi
    # ssh exits 255 after Enter ~ . and the runner passes that through.
    exit "$rc"
  '';
}
