# End-to-end tests of the runner, booting real VMs (needs KVM).
#
# The shell tool execs the host's $SHELL (forwarded by the runner), so
# pointing $SHELL at a probe script makes the tool session run the probe
# instead of an interactive shell. The probe runs inside the ssh session and
# writes what it sees into /workspace; its exit ends the session, the runner
# closes the ssh master, and the guest powers off. The check then asserts on
# those files and on the runner's output.
{ pkgs, shell }:

let
  inherit (pkgs) lib;

  defaultProbe = pkgs.writeShellScript "llmjail-probe" ''
    findmnt() { ${pkgs.util-linux}/bin/findmnt -n -o FSTYPE,SOURCE,OPTIONS "$1"; }
    findmnt / > root
    findmnt /nix/store > store
    findmnt /workspace > share
    # Every TCP listener except dnsmasq on port 53
    ${pkgs.iproute2}/bin/ss -Htln | grep -v ":53 " > tcp
    stat -L -c '%a %U' /dev/virtio-ports/llmjail.ssh > port
    id -un > whoami
    id -Gn > groups
    echo "''${TERM:-}" > term
    # Created only if the guest executed an env value (runner-env-injection)
    ls /workspace/pwned >injected 2>&1
    # The probe's exit status becomes the runner's, and the ls above fails on purpose.
    exit 0
  '';

  # Shared by every test: a writable workspace as cwd, and fail() printing
  # the runner's output.
  prelude =
    {
      probe,
      workspace ? "workspace",
    }:
    ''
      export HOME=$TMPDIR/home SHELL=${probe}

      fail() {
        echo "FAIL: $1 (after $((SECONDS - start))s)"
        echo "--- runner.log ---"
        cat "$TMPDIR/runner.log"
        exit 1
      }

      mkdir -p "$HOME" "$TMPDIR/${workspace}"
      # The builder's uid (nixbld*, 30001+) is already taken by the guest's
      # own nixbld users, so llmjail-set-user-uid keeps `user` at 1000 and
      # the probe could not write to a 0755 workspace owned by the builder.
      chmod 0777 "$TMPDIR/${workspace}"
      cd "$TMPDIR/${workspace}"
      start=$SECONDS
    '';

  # expect/reject are lists of "file:regex" pairs. file is relative to the
  # workspace, except runner.log (the runner's stdout and stderr). A missing
  # file fails an expect and passes a reject.
  mkRunnerTest =
    {
      name,
      runner,
      runnerArgs ? [ ],
      probe ? defaultProbe,
      expect ? [ ],
      expectExit ? 0,
      reject ? [ ],
      extraEnv ? { },
      workspace ? "workspace",
      # Raw shell run before the runner
      setup ? "",
      # Raw shell placed after runnerArgs, for arguments that need $TMPDIR
      rawArgs ? "",
    }:
    pkgs.runCommand "llmjail-runner-${name}"
      {
        requiredSystemFeatures = [ "kvm" ];
      }
      ''
        ${prelude { inherit probe workspace; }}
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") extraEnv)}
        ${setup}

        rc=0
        # Generous: only a hang guard, and flake check boots many VMs at once.
        timeout 300 ${runner}/bin/llm-jail-shell ${lib.escapeShellArgs runnerArgs} ${rawArgs} \
          </dev/null >"$TMPDIR/runner.log" 2>&1 || rc=$?
        echo "runner took $((SECONDS - start))s"
        [ "$rc" = ${toString expectExit} ] || fail "runner exited with $rc, expected ${toString expectExit}"

        resolve() {
          if [ "$1" = runner.log ]; then echo "$TMPDIR/runner.log"; else echo "$1"; fi
        }

        for pair in ${lib.escapeShellArgs expect}; do
          file=$(resolve "''${pair%%:*}") regex=''${pair#*:}
          [ -f "$file" ] || fail "no $file was written"
          grep -Eq -e "$regex" -- "$file" || fail "$file is '$(cat "$file")', expected /$regex/"
          echo "ok: $file matches /$regex/"
        done

        for pair in ${lib.escapeShellArgs reject}; do
          file=$(resolve "''${pair%%:*}") regex=''${pair#*:}
          if [ -f "$file" ] && grep -Eq -e "$regex" -- "$file"; then
            fail "$file is '$(cat "$file")', must not match /$regex/"
          fi
          echo "ok: $file does not match /$regex/"
        done

        touch $out
      '';

  # The overlay is mounted in the initrd, so its options keep the /sysroot
  # prefix.
  storeOverlay = "store:^overlay overlay .*upperdir=/sysroot/\\.nix-upper/store";

  # Checks for every successful boot
  sessionExpect = [
    "whoami:^user$"
    "port:^600 root$"
    "term:^(dumb)?$"
  ];
  sessionReject = [
    "tcp:."
    "groups:(^| )(tty|dialout)( |$)"
    # QEMU exited because the guest powered off, not killed or died early
    "runner.log:VM did not power off within 15 s"
    "runner.log:lost connection to VM"
  ];

  # Writes .llmjailrc and, unless approve is false, the matching approval.
  writeRc =
    {
      content,
      approve ? true,
    }:
    ''
      printf '%s\n' ${lib.escapeShellArg content} > .llmjailrc
      ${lib.optionalString approve ''
        mkdir -p "$HOME/.config/llm-jail"
        echo "$(sha256sum < .llmjailrc | cut -d' ' -f1)  $PWD" >> "$HOME/.config/llm-jail/approved-rc"
      ''}
    '';

  # Records what the rc and the command line resolved to.
  rcProbe = pkgs.writeShellScript "llmjail-probe-rc" ''
    nproc > vcpus
    tr '\0' '|' < /llmjail-env/tool-args > tool-args
    cp /llmjail-env/allowed-domains domains
    # Created only if parsing the rc ran its $(...) on the host
    ls pwned >injected 2>&1
    exit 0
  '';

  # Runs the tmpfs-root shell runner in the background with a custom probe.
  backgroundRunner = probe: ''
    ${prelude { inherit probe; }}
    start_runner() {
      "$@" ${shell}/bin/llm-jail-shell </dev/null >"$TMPDIR/runner.log" 2>&1 &
      RUNNER_PID=$!
    }
  '';
in
{
  runner-tmpfs = mkRunnerTest {
    name = "tmpfs";
    runner = shell;
    expect = [
      "root:^tmpfs rootfs rw"
      storeOverlay
      "share:^9p "
    ] ++ sessionExpect;
    reject = sessionReject;
  };

  runner-disk = mkRunnerTest {
    name = "disk";
    runner = shell;
    runnerArgs = [
      "--disk"
      "1"
    ];
    expect = [
      "root:^ext4 /dev/vda rw"
      storeOverlay
      "share:^9p "
    ] ++ sessionExpect;
    reject = sessionReject;
  };

  runner-virtiofs = mkRunnerTest {
    name = "virtiofs";
    runner = shell.virtiofs;
    runnerArgs = [
      "--disk"
      "1"
    ];
    expect = [
      "root:^ext4 /dev/vda rw"
      storeOverlay
      "share:^virtiofs "
    ] ++ sessionExpect;
    reject = sessionReject;
  };

  runner-exit-status = mkRunnerTest {
    name = "exit-status";
    runner = shell;
    probe = pkgs.writeShellScript "llmjail-probe-exit" "exit 7";
    expectExit = 7;
  };

  # If sourcing the env file executed the value, /workspace/pwned would exist.
  runner-env-injection = mkRunnerTest {
    name = "env-injection";
    runner = shell;
    extraEnv.ANTHROPIC_API_KEY = "$(touch /workspace/pwned)";
    expect = [ "injected:No such file" ];
  };

  # The rc's `--` must not turn the command line's runner flags into tool args.
  runner-rc-merge = mkRunnerTest {
    name = "rc-merge";
    runner = shell;
    probe = rcProbe;
    setup = writeRc { content = "--vcpu 1 \\\n  -- rc-arg \"two words\""; };
    runnerArgs = [
      "--vcpu"
      "2"
      "--"
      "cli-arg"
    ];
    expect = [
      "vcpus:^2$"
      "tool-args:^rc-arg\\|two words\\|cli-arg\\|$"
    ];
  };

  # The `--` is only in the rc, so the command line's flag is still a runner flag.
  runner-rc-syntax = mkRunnerTest {
    name = "rc-syntax";
    runner = shell;
    probe = rcProbe;
    setup = writeRc {
      content = ''
        --allow-domain rc.example
        -- 'single quoted' back\ slash "" $HOME $(touch pwned)
        next-line'';
    };
    runnerArgs = [
      "--allow-domain"
      "cli.example"
    ];
    expect = [
      "tool-args:^single quoted\\|back slash\\|\\|\\$HOME\\|\\$\\(touch\\|pwned\\)\\|next-line\\|$"
      "domains:^rc\\.example$"
      "domains:^cli\\.example$"
      "injected:No such file"
    ];
  };

  # The `--` is only on the command line, so the rc's flag still applies.
  runner-rc-cli-dashes = mkRunnerTest {
    name = "rc-cli-dashes";
    runner = shell;
    probe = rcProbe;
    setup = writeRc { content = "--vcpu 1"; };
    runnerArgs = [
      "--"
      "cli-arg"
    ];
    expect = [
      "vcpus:^1$"
      "tool-args:^cli-arg\\|$"
    ];
  };

  runner-rc-empty = mkRunnerTest {
    name = "rc-empty";
    runner = shell;
    probe = rcProbe;
    setup = writeRc { content = ""; };
    runnerArgs = [
      "--"
      "cli-arg"
    ];
    expect = [ "tool-args:^cli-arg\\|$" ];
  };

  # The rc's last flag must not take the command line's first argument as its value.
  runner-rc-missing-value = mkRunnerTest {
    name = "rc-missing-value";
    runner = shell;
    setup = writeRc { content = "--vcpu"; };
    runnerArgs = [
      "--mem"
      "2000"
    ];
    expectExit = 1;
    expect = [ "runner.log:unbound variable" ];
    reject = [ "runner.log:Booting VM" ];
  };

  runner-rc-unapproved = mkRunnerTest {
    name = "rc-unapproved";
    runner = shell;
    setup = writeRc {
      content = "--vcpu 1";
      approve = false;
    };
    expectExit = 1;
    expect = [ "runner.log:new or changed" ];
    reject = [ "runner.log:Booting VM" ];
  };

  runner-rc-changed = mkRunnerTest {
    name = "rc-changed";
    runner = shell;
    setup = ''
      ${writeRc { content = "--vcpu 1"; }}
      echo "--no-net-filter" > .llmjailrc
    '';
    expectExit = 1;
    expect = [ "runner.log:new or changed" ];
    reject = [ "runner.log:Booting VM" ];
  };

  runner-rc-unbalanced-quote = mkRunnerTest {
    name = "rc-unbalanced-quote";
    runner = shell;
    setup = writeRc { content = ''-- "oops''; };
    expectExit = 1;
    expect = [ "runner.log:could not parse" ];
    reject = [ "runner.log:Booting VM" ];
  };

  # Answers the prompt on a pty. The rc's --tmpdir makes the runner fail right
  # after applying it, so no VM boots: that error proves the rc was applied.
  runner-rc-prompt =
    pkgs.runCommand "llmjail-runner-rc-prompt"
      {
        nativeBuildInputs = [ pkgs.util-linux ];
      }
      ''
        ${prelude { probe = defaultProbe; }}
        ${writeRc {
          content = "--tmpdir /nonexistent";
          approve = false;
        }}
        approvals=$HOME/.config/llm-jail/approved-rc
        answer() {
          # script runs its command through $SHELL, which the prelude set to the probe
          printf '%s\n' "$1" | SHELL=${pkgs.runtimeShell} script -qec ${shell}/bin/llm-jail-shell /dev/null >"$TMPDIR/runner.log" 2>&1 || true
        }

        answer n
        grep -q "not approved" "$TMPDIR/runner.log" || fail "declining did not abort"
        [ ! -e "$approvals" ] || fail "declining stored an approval"

        answer y
        grep -q "tmpdir '/nonexistent' does not exist" "$TMPDIR/runner.log" || fail "approved rc was not applied"
        [ "$(wc -l < "$approvals")" = 1 ] || fail "approval was not stored once"

        # stdin is no terminal now, so this only passes if the approval was remembered
        rc=0
        ${shell}/bin/llm-jail-shell </dev/null >"$TMPDIR/runner.log" 2>&1 || rc=$?
        [ "$rc" = 1 ] || fail "runner exited with $rc, expected 1"
        grep -q "tmpdir '/nonexistent' does not exist" "$TMPDIR/runner.log" || fail "approval was not remembered"

        touch $out
      '';

  # The workspace path ends up in ssh_config, where ssh expands % tokens.
  runner-reject-percent = mkRunnerTest {
    name = "reject-percent";
    runner = shell;
    workspace = "ws%x";
    expectExit = 1;
    expect = [ "runner.log:must not contain '%'" ];
  };

  runner-reject-long-tmpdir = mkRunnerTest {
    name = "reject-long-tmpdir";
    runner = shell;
    setup = ''
      d=$(printf 'a%.0s' {1..100})
      mkdir "$TMPDIR/$d"
    '';
    rawArgs = ''--tmpdir "$TMPDIR/$d"'';
    expectExit = 1;
    expect = [ "runner.log:socket path too long" ];
  };

  # The guest cannot create a mount point under /proc, so llmjail-mounts
  # fails and powers the guest off before the session starts.
  runner-fail-fast = mkRunnerTest {
    name = "fail-fast";
    runner = shell;
    setup = ''mkdir "$TMPDIR/extra"'';
    rawArgs = ''--mount "$TMPDIR/extra:/proc/llmjail"'';
    expectExit = 1;
    expect = [ "runner.log:--- guest\\.log \\(last 200 lines\\) ---" ];
  };

  # Ctrl-C in a non-interactive run reaches only the runner's process group:
  # the session ends, but QEMU and the master's proxy keep running until the
  # guest has powered off cleanly.
  runner-ctrl-c =
    pkgs.runCommand "llmjail-runner-ctrl-c"
      {
        requiredSystemFeatures = [ "kvm" ];
        nativeBuildInputs = [
          pkgs.procps
          pkgs.util-linux
        ];
      }
      ''
        ${backgroundRunner (pkgs.writeShellScript "llmjail-probe-sleep" "touch started; sleep 60")}
        # --default-signal undoes the SIGINT ignore bash gives background jobs
        # (an inherited ignore cannot be trapped). setsid makes the runner lead
        # its own process group without forking, so $! is the runner.
        start_runner env --default-signal=INT setsid

        for (( i=0; i < 3000; i++ )); do
          [ -e started ] && break
          kill -0 "$RUNNER_PID" 2>/dev/null || fail "runner exited before the session started"
          sleep 0.1
        done
        [ -e started ] || fail "session did not start within 300 s"

        # The runner resolves its paths with realpath. The anchors keep the ssh
        # master, whose arguments also contain the socat path, from matching.
        T=$(realpath "$TMPDIR")
        QEMU_PAT="^qemu-system-[^ ]* .*$T"
        SOCAT_PAT="^[^ ]*/bin/socat - UNIX-CONNECT:$T"
        runner_sid=$(ps -o sid= -p "$RUNNER_PID")
        for pat in "$QEMU_PAT" "$SOCAT_PAT"; do
          pids=$(pgrep -f "$pat") || fail "no process matches /$pat/"
          [ "$(echo "$pids" | wc -l)" = 1 ] || fail "several processes match /$pat/: $pids"
          [ "$(ps -o sid= -p "$pids")" != "$runner_sid" ] || fail "/$pat/ runs in the runner's session"
        done

        kill -INT -- "-$RUNNER_PID"
        timeout 60 tail --pid="$RUNNER_PID" -f /dev/null || fail "runner did not exit within 60 s of SIGINT"
        rc=0
        wait "$RUNNER_PID" || rc=$?
        [ "$rc" != 0 ] || fail "runner exited 0 after SIGINT"

        for msg in "VM did not power off within 15 s" "lost connection to VM"; do
          if grep -q "$msg" "$TMPDIR/runner.log"; then fail "runner printed '$msg'"; fi
        done
        if pgrep -f "$QEMU_PAT"; then fail "QEMU still running"; fi

        touch $out
      '';

  # The printed inspection command opens a shell as `user`, the private key and
  # ssh_config stay out of the guest's share, and open inspection shells end
  # with the tool session.
  runner-inspect =
    pkgs.runCommand "llmjail-runner-inspect"
      {
        requiredSystemFeatures = [ "kvm" ];
      }
      ''
        ${backgroundRunner (pkgs.writeShellScript "llmjail-probe-wait" ''
          for (( i=0; i < 600; i++ )); do
            [ -e go ] && exit 0
            sleep 0.1
          done
          exit 1
        '')}
        start_runner timeout 600

        cmd=
        for (( i=0; i < 3000; i++ )); do
          cmd=$(sed -n 's/^To open a shell in this jail: //p' "$TMPDIR/runner.log")
          [ -n "$cmd" ] && break
          kill -0 "$RUNNER_PID" 2>/dev/null || fail "runner exited without printing the inspection command"
          sleep 0.1
        done
        [ -n "$cmd" ] || fail "no inspection command within 300 s"
        echo "inspection command: $cmd"

        read -ra argv <<<"$cmd"
        RUNDIR=$(dirname "''${argv[2]}")

        output=$("''${argv[@]}" id -un </dev/null) || fail "inspection command failed"
        [ "$output" = user ] || fail "inspection shell runs as '$output', expected user"

        [ "$(stat -c %a "$RUNDIR")" = 700 ] || fail "$RUNDIR is not mode 700"
        for f in id ssh_config; do
          [ ! -e "$RUNDIR/share/$f" ] || fail "$f is shared with the guest"
        done

        "''${argv[@]}" sleep 300 </dev/null &
        inspect_pid=$!

        touch go
        rc=0
        wait "$RUNNER_PID" || rc=$?
        [ "$rc" = 0 ] || fail "runner exited with $rc"

        for (( i=0; i < 25; i++ )); do
          kill -0 "$inspect_pid" 2>/dev/null || break
          sleep 0.2
        done
        if kill -0 "$inspect_pid" 2>/dev/null; then fail "inspection shell outlived the tool session"; fi

        touch $out
      '';
}
