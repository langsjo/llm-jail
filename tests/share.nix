# llmjail-share without a VM: runs the helper over a git repository with a
# submodule and a linked worktree, and in place of virtiofsd a script that
# checks, from inside the namespace, what the file server would see. Runs in
# the Nix build sandbox, which allows user and mount namespaces.
{ pkgs }:

let
  share = import ../lib/share.nix { inherit pkgs; };

  # Prints "<check>: yes" or "<check>: no" for each check, from the share root.
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
    t() {
      if eval "$2" >/dev/null 2>&1; then echo "$1: yes"; else echo "$1: no"; fi
    }
    t "masked file reads empty" '[ -z "$(cat .env)" ]'
    t "masked file in a subdirectory reads empty" '[ -z "$(cat sub/.env)" ]'
    t "masked directory lists empty" '[ -z "$(ls -A secrets)" ]'
    t "path glob masks its match" '[ -z "$(cat docs/a.key)" ]'
    t "path glob leaves other files" 'grep -q readme docs/readme'
    t "masked symlink still readable" 'grep -q target link'
    t "masked file writable" 'echo x > .env'
    t "masked file removable" 'rm .env'
    t "config writable" 'echo x >> .git/config'
    t "config replaceable" 'cp .git/config c && mv c .git/config'
    t "config.worktree writable" 'echo x >> .git/config.worktree'
    t "hook creatable" 'touch .git/hooks/pre-commit'
    t "submodule config writable" 'echo x >> .git/modules/sub-repo/config'
    t "submodule hook creatable" 'touch .git/modules/sub-repo/hooks/post-checkout'
    t "worktree config writable" 'echo x >> .git/worktrees/wt/config.worktree'
    t "commit possible" 'git -c user.name=t -c user.email=t@t commit -q --allow-empty -m from-the-share'
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
    commit possible: yes
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
    sha256sum .git/config .git/config.worktree .git/modules/sub-repo/config .git/worktrees/wt/config.worktree > ../before
    cd ..

    ${share}/bin/llmjail-share --mask .env --mask secrets --mask 'docs/*.key' --mask link --protect-git \
      "$PWD/ws" -- ${checks} "$PWD/ws" > results 2> warnings
    cat warnings
    diff -u ${expected} results

    grep -q "symlink, not masked: $PWD/ws/link" warnings
    # The host's files are untouched, the commit landed, the hooks directory
    # exists, and no scratch directory was left behind.
    (cd ws && sha256sum -c --quiet ../before)
    grep -qx secret ws/.env ws/sub/.env ws/secrets/key ws/docs/a.key
    git -C ws log --format=%s | grep -qx from-the-share
    [ -d ws/.git/hooks ] && [ -z "$(ls -A ws/.git/hooks)" ]
    [ -z "$(find "$TMPDIR" -maxdepth 1 -name 'tmp.*')" ]

    # A gitdir outside the share is not exported, so it is left alone.
    mkdir outside-share elsewhere
    echo "gitdir: ../elsewhere" > outside-share/.git
    ${share}/bin/llmjail-share --protect-git "$PWD/outside-share" -- \
      ${pkgs.runtimeShell} -c "echo x > $PWD/elsewhere/config"
    grep -qx x elsewhere/config

    touch $out
  ''
