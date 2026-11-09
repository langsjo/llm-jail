# llmjail-share: runs a share's file server with paths hidden or protected
# from the guest.
#
#   llmjail-share [--mask GLOB]... [--protect-git] ROOT -- COMMAND...
#
#   --mask GLOB    cover every path under ROOT matching GLOB with an empty,
#                  read-only file or directory. A GLOB with a `/` matches with
#                  `find -path "ROOT/GLOB"`, any other with `find -name GLOB`.
#   --protect-git  make the files host git executes code from read-only (see
#                  protect_repo below).
#
# It re-executes itself in a new user and mount namespace owned by the
# invoking user (no host privileges), applies bind mounts there, drops every
# capability and execs COMMAND (virtiofsd). Nothing COMMAND serves can undo
# the mounts: they exist in this namespace only, virtiofsd's nested sandbox
# locks them, and it has no capabilities. Paths are resolved once, so paths
# created later are not covered.
{ pkgs }:

pkgs.writeShellApplication {
  name = "llmjail-share";
  runtimeInputs = with pkgs; [
    coreutils
    findutils
    gnused
    util-linux
  ];
  text = ''
    if [ "''${LLMJAIL_SHARE_NS:-}" != 1 ]; then
      LLMJAIL_SHARE_NS=1 exec unshare --user --map-current-user --keep-caps --mount -- "$0" "$@"
    fi
    unset LLMJAIL_SHARE_NS

    MASKS=()
    PROTECT_GIT=0
    ROOT=
    while [ $# -gt 0 ]; do
      case "$1" in
        --mask) MASKS+=("$2"); shift 2 ;;
        --protect-git) PROTECT_GIT=1; shift ;;
        --) shift; break ;;
        -*) echo "llmjail-share: unknown option $1" >&2; exit 1 ;;
        *) ROOT=$(realpath -e -- "$1"); shift ;;
      esac
    done
    if [ -z "$ROOT" ] || [ $# -eq 0 ]; then
      echo "usage: llmjail-share [--mask GLOB]... [--protect-git] ROOT -- COMMAND..." >&2
      exit 1
    fi

    warn() {
      echo "llmjail-share: $*" >&2
    }

    read_only() {
      mount -o remount,bind,ro -- "$1"
    }

    # rbind keeps host mounts below the path in place.
    protect() {
      mount --rbind -- "$1" "$1"
      read_only "$1"
    }

    # PATH resolved through symlinks, if it stays inside the share; anything
    # else is not exported anyway.
    inside_root() {
      local real
      real=$(realpath -e -- "$1" 2>/dev/null) || return 1
      [[ "$real" == "$ROOT" || "$real" == "$ROOT"/* ]] || return 1
      echo "$real"
    }

    # Host git runs code named in these files (core.hooksPath,
    # core.fsmonitor, core.sshCommand, filter drivers) and its hooks, so the
    # agent must not be able to write them. Covers the share's own
    # repository: its gitdir (also when .git is a `gitdir:` file), a
    # worktree's common dir, and every submodule gitdir below them.
    protect_repo() {
      local gitdir d head file
      local dirs=()
      if [ -d "$ROOT/.git" ]; then
        gitdir=$ROOT/.git
      elif [ -f "$ROOT/.git" ]; then
        gitdir=$(sed -n 's/^gitdir: //p' "$ROOT/.git")
        [[ "$gitdir" == /* ]] || gitdir=$ROOT/$gitdir
      else
        return 0
      fi
      gitdir=$(inside_root "$gitdir") || return 0
      dirs+=("$gitdir")
      if [ -f "$gitdir/commondir" ]; then
        d=$(cat "$gitdir/commondir")
        [[ "$d" == /* ]] || d=$gitdir/$d
        if d=$(inside_root "$d"); then
          dirs+=("$d")
        fi
      fi
      # A submodule gitdir has HEAD, config and objects (refs/remotes/*/HEAD
      # files do not).
      for d in "''${dirs[@]}"; do
        [ -d "$d/modules" ] || continue
        while IFS= read -r -d "" head; do
          d=''${head%/HEAD}
          if [ -f "$d/config" ] && [ -d "$d/objects" ]; then
            dirs+=("$d")
          fi
        done < <(find "$d/modules" -name HEAD -type f -print0)
      done
      for d in "''${dirs[@]}"; do
        # Read-only even when missing, or the agent could create it.
        mkdir -p "$d/hooks"
        for file in "$d/config" "$d/config.worktree" "$d/hooks" "$d"/worktrees/*/config.worktree; do
          if file=$(inside_root "$file"); then
            protect "$file"
          fi
        done
      done
    }

    # What masked paths are covered with: a tmpfs private to this namespace.
    # Once bound over the masked paths it stays alive through those mounts, so
    # its own mount point is removed again and nothing is left on the host.
    EMPTY=$(mktemp -d)
    mount -t tmpfs -o size=4k llmjail-empty "$EMPTY"
    mkdir -m 0555 "$EMPTY/dir"
    install -m 0444 /dev/null "$EMPTY/file"

    mask_paths() {
      local p target
      local expr=()
      for p in "''${MASKS[@]+"''${MASKS[@]}"}"; do
        if [ ''${#expr[@]} -gt 0 ]; then expr+=("-o"); fi
        case "$p" in
          */*) expr+=("-path" "$ROOT/$p") ;;
          *) expr+=("-name" "$p") ;;
        esac
      done
      [ ''${#expr[@]} -gt 0 ] || return 0
      # -prune: a masked directory is covered whole.
      while IFS= read -r -d "" target; do
        [ "$target" = "$ROOT" ] && continue
        # A bind would follow the link and cover its target instead.
        if [ -L "$target" ]; then
          warn "--mask matches a symlink, not masked: $target"
          continue
        fi
        if [ -d "$target" ]; then
          mount --bind -- "$EMPTY/dir" "$target"
        else
          mount --bind -- "$EMPTY/file" "$target"
        fi
        read_only "$target"
      done < <(find "$ROOT" \( "''${expr[@]}" \) -prune -print0)
    }

    # Read-only binds first, so masks inside them land on top.
    if [ "$PROTECT_GIT" = 1 ]; then
      protect_repo
    fi
    mask_paths
    umount --lazy "$EMPTY"
    rmdir "$EMPTY"

    exec setpriv --pdeathsig KILL --bounding-set=-all --inh-caps=-all --ambient-caps=-all -- "$@"
  '';
}
