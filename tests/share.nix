# llmjail-share without a VM: runs the helper over a git repository with a
# submodule and a linked worktree, and in place of virtiofsd a script that
# checks, from inside the namespace, what the file server would see. Runs in
# the Nix build sandbox, which allows user and mount namespaces.
{ pkgs }:

let
  share = import ../lib/share.nix { inherit pkgs; };

  # Prints "<check>: yes" or "<check>: no" for each check, from the share
  # root. The attacks plant a command that creates the marker file $2 when
  # host git runs it, so after the run host git proves they failed.
  checks = pkgs.writeShellScript "llmjail-share-checks" ''
    PATH=${
      pkgs.lib.makeBinPath [
        pkgs.coreutils
        pkgs.git
        pkgs.gnugrep
        pkgs.util-linux
      ]
    }
    cd "$1"
    MARK=$2
    t() {
      if eval "$2" >/dev/null 2>&1; then echo "$1: yes"; else echo "$1: no"; fi
    }
    # Appends a config section that makes host git run `touch $MARK`.
    poison() {
      printf '[core]\n\tfsmonitor = "touch %s; false"\n' "$MARK" >> "$1"
    }
    hook() {
      printf '#!/bin/sh\ntouch %s\n' "$MARK" > "$1" && chmod +x "$1"
    }
    t "masked file reads empty" '[ -z "$(cat .env)" ]'
    t "masked file in a subdirectory reads empty" '[ -z "$(cat sub/.env)" ]'
    t "masked directory lists empty" '[ -z "$(ls -A secrets)" ]'
    t "path glob masks its match" '[ -z "$(cat docs/a.key)" ]'
    t "path glob leaves other files" 'grep -q readme docs/readme'
    t "masked symlink still readable" 'grep -q target link'
    t "masked file writable" 'echo x > .env'
    t "masked file removable" 'rm .env'
    t "config writable" 'poison .git/config'
    t "config replaceable" 'cp .git/config c && poison c && mv c .git/config'
    t "config.worktree writable" 'poison .git/config.worktree'
    t "hook creatable" 'hook .git/hooks/post-checkout'
    t "submodule config writable" 'poison .git/modules/sub-repo/config'
    t "submodule hook creatable" 'hook .git/modules/sub-repo/hooks/post-checkout'
    t "worktree config writable" 'poison .git/worktrees/wt/config.worktree'
    t "worktree commondir writable" 'echo .. > .git/worktrees/wt/commondir'
    t "gitdir replaceable by a copy" 'mv .git .git-old && cp -a .git-old .git && poison .git/config'
    t "submodule gitdir replaceable by a copy" 'mv .git/modules .git/m && cp -a .git/m .git/modules && poison .git/modules/sub-repo/config'
    t "worktree admin dir replaceable by a copy" 'mv .git/worktrees .git/w && cp -a .git/w .git/worktrees && poison .git/worktrees/wt/config.worktree'
    t "submodule .git file writable" 'mkdir evil && cp -r .git/modules/sub-repo/. evil/ && git config -f evil/config --unset core.worktree; poison evil/config && echo "gitdir: ../evil" > sub-repo/.git'
    t "submodule checkout replaceable" 'mv sub-repo s && git init -q sub-repo && poison sub-repo/.git/config'
    t "worktree .git file writable" 'echo "gitdir: ../evil" > wt/.git'
    t "global relative hooksPath creatable" 'mkdir -p .githooks && hook .githooks/post-checkout'
    t "included config writable" 'poison shared.gitconfig'
    t "commit possible" 'git -c user.name=t -c user.email=t@t commit -q --allow-empty -m from-the-share'
    t "checkout possible" 'git checkout -q -b branch && git checkout -q main'
    t "submodule commit possible" 'git -C sub-repo -c user.name=t -c user.email=t@t commit -q --allow-empty -m from-the-share'
    t "mask unmountable" 'umount .env'
    t "capabilities left" '! grep -q "^CapEff:[[:space:]]*0*$" /proc/self/status'
  '';

  expected = pkgs.writeText "llmjail-share-expected" ''
    masked file reads empty: yes
    masked file in a subdirectory reads empty: yes
    masked directory lists empty: yes
    path glob masks its match: yes
    path glob leaves other files: yes
    masked symlink still readable: yes
    masked file writable: no
    masked file removable: no
    config writable: no
    config replaceable: no
    config.worktree writable: no
    hook creatable: no
    submodule config writable: no
    submodule hook creatable: no
    worktree config writable: no
    worktree commondir writable: no
    gitdir replaceable by a copy: no
    submodule gitdir replaceable by a copy: no
    worktree admin dir replaceable by a copy: no
    submodule .git file writable: no
    submodule checkout replaceable: no
    worktree .git file writable: no
    global relative hooksPath creatable: no
    included config writable: no
    commit possible: yes
    checkout possible: yes
    submodule commit possible: yes
    mask unmountable: no
    capabilities left: no
  '';
in
pkgs.runCommand "llmjail-share-test"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.diffutils
    ];
  }
  ''
    export HOME=$TMPDIR/home
    mkdir -p "$HOME" ws
    git config --global user.name t
    git config --global user.email t@t
    git config --global protocol.file.allow always
    git config --global init.defaultBranch main

    git init -q sub-src
    git -C sub-src commit -q --allow-empty -m sub
    cd ws
    git init -q
    git submodule -q add ../sub-src sub-repo
    git commit -q -m init
    git config extensions.worktreeConfig true
    git config --worktree core.x y
    git worktree add -q wt
    git -C wt config --worktree core.x y
    # Included from inside the share.
    touch shared.gitconfig
    git config include.path ../shared.gitconfig
    # A repository without hooks gets them created read-only.
    rm -r .git/hooks
    echo secret > .env
    mkdir sub secrets docs
    echo secret > sub/.env
    echo secret > secrets/key
    echo secret > docs/a.key
    echo readme > docs/readme
    echo target > target
    ln -s target link
    PROTECTED=(.git/config .git/config.worktree .git/modules/sub-repo/config .git/worktrees/wt/config.worktree
      .git/worktrees/wt/commondir sub-repo/.git wt/.git shared.gitconfig)
    sha256sum "''${PROTECTED[@]}" > ../before
    cd ..

    # A relative hooksPath in the global config resolves inside each worktree;
    # the helper creates it read-only. Set only for the helper's run.
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=.githooks \
      ${share}/bin/llmjail-share --mask .env --mask secrets --mask 'docs/*.key' --mask link --protect-git \
      "$PWD/ws" -- ${checks} "$PWD/ws" "$PWD/pwned" > results 2> warnings || {
      cat warnings results; echo "llmjail-share failed"; exit 1
    }
    cat warnings
    diff -u ${expected} results

    grep -q "symlink, not masked: $PWD/ws/link" warnings
    # The host's files are untouched, the commits landed, the hooks directories
    # exist, and no scratch directory was left behind.
    (cd ws && sha256sum -c --quiet ../before)
    grep -qx secret ws/.env ws/sub/.env ws/secrets/key ws/docs/a.key
    git -C ws log --format=%s | grep -qx from-the-share
    git -C ws/sub-repo log --format=%s | grep -qx from-the-share
    [ -d ws/.git/hooks ] && [ -z "$(ls -A ws/.git/hooks)" ]
    [ -d ws/.githooks ] && [ -z "$(ls -A ws/.githooks)" ]
    [ -z "$(find "$TMPDIR" -maxdepth 1 -name 'tmp.*')" ]
    # Host git, everywhere an attack aimed, runs none of the planted code.
    git -C ws status > /dev/null
    git -C ws checkout -q -b after-the-run
    git -C ws/sub-repo status > /dev/null
    git -C ws/sub-repo checkout -q -b after-the-run
    git -C ws/wt status > /dev/null
    [ ! -e pwned ]

    # A gitdir outside the share is not exported, so it is left alone.
    mkdir outside-share elsewhere
    echo "gitdir: ../elsewhere" > outside-share/.git
    ${share}/bin/llmjail-share --protect-git "$PWD/outside-share" -- \
      ${pkgs.runtimeShell} -c "echo x > $PWD/elsewhere/config"
    grep -qx x elsewhere/config

    # A missing config.worktree is created empty and read-only when the
    # repository reads it.
    git init -q wtc
    git -C wtc config extensions.worktreeConfig true
    ${share}/bin/llmjail-share --protect-git "$PWD/wtc" -- \
      ${pkgs.runtimeShell} -c "! echo x 2>/dev/null >> $PWD/wtc/.git/config.worktree"
    [ -f wtc/.git/config.worktree ] && [ ! -s wtc/.git/config.worktree ]

    # Refused: a protected path reached through a symlink in the share (the
    # link could be repointed), and an include the guest could create.
    refused() {
      if ${share}/bin/llmjail-share --protect-git "$1" -- true 2> refusal; then
        echo "not refused: $1"; exit 1
      fi
      cat refusal
      grep -q "$2" refusal
    }
    git init -q linked
    mkdir linked/tools
    mv linked/.git/hooks linked/tools/hooks
    ln -s ../tools/hooks linked/.git/hooks
    refused "$PWD/linked" "hooks goes through a symlink"
    git init -q include-missing
    git -C include-missing config include.path ../missing.gitconfig
    refused "$PWD/include-missing" "missing.gitconfig, which does not exist"

    touch $out
  ''
