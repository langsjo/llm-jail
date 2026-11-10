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
    git
    gnused
    util-linux
  ];
  text = ''
    # A private first argument rather than an environment variable, which the
    # caller's environment could already carry.
    if [ "''${1:-}" != --in-namespace ]; then
      exec unshare --user --map-current-user --keep-caps --mount -- "$0" --in-namespace "$@"
    fi
    shift

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

    die() {
      warn "$*"
      exit 1
    }

    inside_root() {
      [[ "$1" == "$ROOT" || "$1" == "$ROOT"/* ]]
    }

    # Sets REAL to PATH with symlinks resolved, and succeeds if that exists
    # inside the share (anything else is not exported). Exits when PATH goes
    # through a symlink inside the share: the guest could point the link
    # elsewhere, and Linux cannot mount over a symlink to pin it.
    resolve() {
      local lexical
      lexical=$(realpath -m -s -- "$1")
      REAL=$(realpath -m -- "$1")
      if [ "$lexical" != "$REAL" ] && inside_root "$lexical"; then
        die "$1 goes through a symlink inside the share, which the guest could replace; refusing to start (for a hooks directory, set core.hooksPath instead of linking it)"
      fi
      [ -e "$REAL" ] && inside_root "$REAL"
    }

    declare -A SEEN=()
    READ_ONLY=()
    PINNED=()

    read_only() {
      if resolve "$1" && [ -z "''${SEEN[ro:$REAL]:-}" ]; then
        SEEN[ro:$REAL]=1
        READ_ONLY+=("$REAL")
      fi
    }

    # A pinned directory is a mount point, so it cannot be renamed or removed
    # (EBUSY), while everything in it stays writable.
    pin() {
      if resolve "$1" && [ -z "''${SEEN[pin:$REAL]:-}" ]; then
        SEEN[pin:$REAL]=1
        PINNED+=("$REAL")
      fi
    }

    # Host git without the caller's repository overrides; it only reads
    # configuration here, which runs nothing.
    host_git() {
      env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git "$@"
    }

    # Host git runs code named in config files (core.hooksPath,
    # core.fsmonitor, core.sshCommand, filter drivers), from its hooks, and
    # from wherever control files point it (commondir, `gitdir:` files). For
    # the share's own repository, every submodule gitdir and every linked
    # worktree's admin dir, those files are read-only and the gitdirs pinned,
    # so a gitdir cannot be moved aside and replaced with a copy. Not covered:
    # control files that do not exist yet (a new commondir), gitlinks the
    # agent adds to the index, and repositories it plants.
    protect_repo() {
      local gitdir d head f i
      local gitdirs=()
      resolve "$ROOT/.git" || return 0
      gitdir=$REAL
      if [ -f "$gitdir" ]; then
        d=$(sed -n 's/^gitdir: //p' "$gitdir")
        [[ "$d" == /* ]] || d=$ROOT/$d
        resolve "$d" || return 0
        gitdir=$REAL
      fi
      gitdirs+=("$gitdir")
      if [ -f "$gitdir/commondir" ]; then
        d=$(cat "$gitdir/commondir")
        [[ "$d" == /* ]] || d=$gitdir/$d
        if resolve "$d"; then
          gitdirs+=("$REAL")
        fi
      fi
      # Indexed, so dirs found here are searched too. A submodule gitdir has
      # HEAD, config and objects (refs/remotes/*/HEAD files do not).
      for (( i = 0; i < ''${#gitdirs[@]}; i++ )); do
        d=''${gitdirs[i]}
        for f in "$d"/worktrees/*/; do
          if [ -d "$f" ]; then
            gitdirs+=("''${f%/}")
          fi
        done
        [ -d "$d/modules" ] || continue
        while IFS= read -r -d "" head; do
          f=''${head%/HEAD}
          if [ -f "$f/config" ] && [ -d "$f/objects" ]; then
            gitdirs+=("$f")
          fi
        done < <(find "$d/modules" -name HEAD -type f -print0)
      done
      for d in "''${gitdirs[@]}"; do
        pin "$d"
        # Read-only even when missing, or the agent could create them.
        if [ -d "$d/objects" ] && [ ! -e "$d/hooks" ] && [ ! -L "$d/hooks" ]; then
          mkdir "$d/hooks"
        fi
        if [ ! -e "$d/config.worktree" ] && [ ! -L "$d/config.worktree" ] &&
          [ "$(host_git --git-dir="$d" config --type=bool --get extensions.worktreeConfig 2>/dev/null)" = true ]; then
          : > "$d/config.worktree"
        fi
        for f in config config.worktree commondir hooks; do
          read_only "$d/$f"
        done
      done
    }

    # Every `.git` file in the share (the root's own, submodule checkouts,
    # linked worktrees), rewritten, would point host git at another gitdir.
    # Host git in each of those worktrees also runs the hooks directory and
    # loads the config files it resolves there: core.hooksPath (a relative
    # one, also from your global config, lands inside the worktree),
    # include.path targets, a ~/.gitconfig inside the share.
    protect_worktrees() {
      local dotgit wt hooks origin entry key value
      local worktrees=()
      if [ -e "$ROOT/.git" ]; then
        worktrees+=("$ROOT")
      fi
      while IFS= read -r -d "" dotgit; do
        read_only "$dotgit"
        worktrees+=("''${dotgit%/.git}")
      done < <(find "$ROOT" -name .git -type d -prune -o -name .git -type f -print0)

      for wt in "''${worktrees[@]+"''${worktrees[@]}"}"; do
        if hooks=$(host_git -C "$wt" rev-parse --git-path hooks 2>/dev/null); then
          [[ "$hooks" == /* ]] || hooks=$wt/$hooks
          if ! resolve "$hooks" && inside_root "$REAL"; then
            mkdir -p "$REAL"
          fi
          read_only "$hooks"
        fi
        while IFS= read -r -d "" origin && IFS= read -r -d "" entry; do
          [[ "$origin" == file:* ]] || continue
          origin=''${origin#file:}
          [[ "$origin" == /* ]] || origin=$wt/$origin
          read_only "$origin"
        done < <(host_git -C "$wt" config --list --show-origin --includes -z 2>/dev/null)
        # Include targets once more: an empty one has no entries above, and
        # one that does not exist yet would be created by the agent.
        while IFS= read -r -d "" origin && IFS= read -r -d "" entry; do
          [[ "$origin" == file:* ]] || continue
          origin=''${origin#file:}
          [[ "$origin" == /* ]] || origin=$wt/$origin
          key=''${entry%%$'\n'*}
          value=''${entry#*$'\n'}
          [[ "$value" == /* ]] || value=$(dirname -- "$origin")/$value
          if ! resolve "$value" && inside_root "$REAL"; then
            die "$key in $origin names $value, which does not exist; the guest could create it, refusing to start"
          fi
          read_only "$value"
        done < <(host_git -C "$wt" config --show-origin -z --type=path --get-regexp '^include(if\..*)?\.path$' 2>/dev/null)
      done
    }

    # NUL-separated, sorted and deduplicated; nothing at all for no arguments.
    sorted_unique() {
      if [ $# -gt 0 ]; then
        printf '%s\0' "$@" | LC_ALL=C sort -zu
      fi
    }

    # Pinned directories, and every directory between the share root and a
    # protected path, are bound onto themselves first (sorted, so parents come
    # first), then the read-only binds go on top. rbind keeps host mounts
    # below each path in place.
    apply_protection() {
      local p d
      local dirs=()
      for p in "''${READ_ONLY[@]+"''${READ_ONLY[@]}"}" "''${PINNED[@]+"''${PINNED[@]}"}"; do
        d=$p
        while d=$(dirname -- "$d"); [ "$d" != "$ROOT" ] && inside_root "$d"; do
          dirs+=("$d")
        done
      done
      dirs+=("''${PINNED[@]+"''${PINNED[@]}"}")
      while IFS= read -r -d "" d; do
        mount --rbind -- "$d" "$d"
      done < <(sorted_unique "''${dirs[@]+"''${dirs[@]}"}")
      while IFS= read -r -d "" p; do
        mount --rbind -- "$p" "$p"
        mount -o remount,bind,ro -- "$p"
      done < <(sorted_unique "''${READ_ONLY[@]+"''${READ_ONLY[@]}"}")
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
        mount -o remount,bind,ro -- "$target"
      done < <(find "$ROOT" \( "''${expr[@]}" \) -prune -print0)
    }

    # Everything is found before anything is mounted. Read-only binds come
    # before masks, so masks inside them land on top.
    if [ "$PROTECT_GIT" = 1 ]; then
      protect_repo
      protect_worktrees
      apply_protection
    fi
    mask_paths
    # libmount treats our uid as an unprivileged user and, with only --lazy,
    # allows the unmount just for an /etc/fstab "user" mount (it fails
    # outright where there is no fstab, as in the Nix build sandbox). Any
    # option outside its short list for users, such as --no-mtab (a no-op),
    # makes it leave the decision to the kernel, as mount above does.
    umount --no-mtab --lazy "$EMPTY"
    rmdir "$EMPTY"

    exec setpriv --pdeathsig KILL --bounding-set=-all --inh-caps=-all --ambient-caps=-all -- "$@"
  '';
}
