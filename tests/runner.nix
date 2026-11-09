# Tests of the runner script.
#
# Tests that stop before the VM boots (argument and .llmjailrc handling) are
# plain derivations. Tests that boot a jail run in the NixOS test framework,
# where a `host` VM runs the runner the way a real host does, as an
# unprivileged user with KVM (the jail is a nested VM, so nested KVM keeps
# them fast).
#
# The shell tool execs the host's $SHELL (forwarded by the runner), so
# pointing $SHELL at a probe script makes the tool session run the probe
# instead of an interactive shell. The probe runs inside the ssh session and
# writes what it sees into /workspace; its exit ends the session, the runner
# closes the ssh master, and the guest powers off. The test then checks
# those files and the runner's output.
{ pkgs, shell }:

let
  inherit (pkgs) lib;

  # ---------------------------------------------------------------------------
  # Pre-boot tests

  # Shared by every pre-boot test: a workspace as cwd, and fail() printing
  # the runner's output.
  prelude =
    {
      workspace ? "workspace",
    }:
    ''
      export HOME=$TMPDIR/home

      fail() {
        echo "FAIL: $1"
        echo "--- runner.log ---"
        cat "$TMPDIR/runner.log"
        exit 1
      }

      mkdir -p "$HOME" "$TMPDIR/${workspace}"
      cd "$TMPDIR/${workspace}"
    '';

  # expect/reject are lists of "regex"es matched against the runner's output.
  mkPrebootTest =
    {
      name,
      runnerArgs ? [ ],
      expect ? [ ],
      expectExit ? 1,
      reject ? [ "Booting VM" ],
      workspace ? "workspace",
      # Raw shell run before the runner
      setup ? "",
      # Raw shell placed after runnerArgs, for arguments that need $TMPDIR
      rawArgs ? "",
    }:
    pkgs.runCommand "llmjail-runner-${name}" { } ''
      ${prelude { inherit workspace; }}
      ${setup}

      rc=0
      timeout 60 ${shell}/bin/llm-jail-shell ${lib.escapeShellArgs runnerArgs} ${rawArgs} \
        </dev/null >"$TMPDIR/runner.log" 2>&1 || rc=$?
      [ "$rc" = ${toString expectExit} ] || fail "runner exited with $rc, expected ${toString expectExit}"

      for regex in ${lib.escapeShellArgs expect}; do
        grep -Eq -e "$regex" "$TMPDIR/runner.log" || fail "runner output does not match /$regex/"
      done
      for regex in ${lib.escapeShellArgs reject}; do
        if grep -Eq -e "$regex" "$TMPDIR/runner.log"; then fail "runner output matches /$regex/"; fi
      done

      touch $out
    '';

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

  # ---------------------------------------------------------------------------
  # VM tests

  sessionProbe = pkgs.writeShellScript "llmjail-probe" ''
    findmnt() { ${pkgs.util-linux}/bin/findmnt -n -o FSTYPE,SOURCE,OPTIONS "$1"; }
    findmnt / > root
    findmnt /nix/store > store
    findmnt /workspace > share
    # Every TCP listener except the guest's dnsmasq on port 53
    ${pkgs.iproute2}/bin/ss -Htln | grep -v ":53 " > tcp
    stat -L -c '%a %U' /dev/virtio-ports/llmjail.ssh > port
    id -un > whoami
    id -Gn > groups
    echo "''${TERM:-}" > term
    # Created only if the guest executed an env value
    ls /workspace/pwned >injected 2>&1
    # The probe's exit status becomes the runner's, and the ls above fails on purpose.
    exit 0
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

  hostNode =
    { ... }:
    {
      virtualisation = {
        memorySize = 3072;
        cores = 2;
      };
      users.users.alice = {
        isNormalUser = true;
        extraGroups = [ "kvm" ];
      };
      environment.systemPackages = [
        shell
        pkgs.curl
        pkgs.git
        pkgs.procps
        pkgs.socat
      ];
    };

  # Python helpers for the VM tests.
  #
  # jail() runs the shell runner as alice in a fresh workspace ~/ws, with the
  # probe as the tool, and returns its output. setup is shell run in the
  # workspace first; env is prepended to the runner's command line.
  helpers = ''
    import re
    import shlex

    def jail(probe, args="", setup="", env="", expect_exit=0):
        script = f"""
          set -eu
          export SHELL={probe}
          rm -rf ~/ws
          mkdir ~/ws
          cd ~/ws
          {setup}
          rc=0
          {env} timeout 900 llm-jail-shell --mem 1024 {args} </dev/null >~/runner.log 2>&1 || rc=$?
          echo $rc >~/rc
        """
        host.succeed(f"su - alice -c {shlex.quote(script)}")
        log = host.succeed("cat ~alice/runner.log")
        rc = int(host.succeed("cat ~alice/rc"))
        assert rc == expect_exit, f"runner exited with {rc}, expected {expect_exit}:\n{log}"
        return log

    def ws(path):
        return host.succeed(f"cat ~alice/ws/{path}")

    # Shell that writes .llmjailrc and, unless approve is False, its approval.
    def rc_setup(content, approve=True):
        script = f"printf '%s\\n' {shlex.quote(content)} > .llmjailrc\n"
        if approve:
            script += "mkdir -p ~/.config/llm-jail\n"
            script += "echo \"$(sha256sum < .llmjailrc | cut -d' ' -f1)  $PWD\" >> ~/.config/llm-jail/approved-rc\n"
        return script

    def expect(text, regex, what):
        assert re.search(regex, text, re.M), f"{what} is {text!r}, expected /{regex}/"

    def reject(text, regex, what):
        assert not re.search(regex, text, re.M), f"{what} is {text!r}, must not match /{regex}/"

    # Checks for every session that ran to its end.
    def clean_session(log):
        expect(ws("whoami"), "^user$", "whoami")
        expect(ws("port"), "^600 root$", "port")
        expect(ws("term"), "^(dumb)?$", "term")
        reject(ws("tcp"), ".", "guest TCP listeners")
        reject(ws("groups"), "(^| )(tty|dialout)( |$)", "groups")
        reject(log, "VM did not power off within 15 s", "runner output")
        reject(log, "lost connection to VM", "runner output")

    def wait_for_host():
        host.wait_for_unit("multi-user.target")
        host.succeed("test -c /dev/kvm")
  '';

  # host extends the shared host node; other nodes are added as given.
  mkVmTest =
    {
      name,
      host ? { },
      nodes ? { },
      testScript,
    }:
    pkgs.testers.nixosTest {
      name = "llmjail-runner-${name}";
      nodes = nodes // {
        host.imports = [
          hostNode
          host
        ];
      };
      testScript =
        { nodes, ... }@args:
        helpers
        + ''
          start_all()
          wait_for_host()
        ''
        + testScript args;
    };

in
{
  # ---------------------------------------------------------------------------
  # Pre-boot tests

  # The rc's last flag must not take the command line's first argument as its value.
  runner-rc-missing-value = mkPrebootTest {
    name = "rc-missing-value";
    setup = writeRc { content = "--vcpu"; };
    runnerArgs = [
      "--mem"
      "2000"
    ];
    expect = [ "unbound variable" ];
  };

  runner-rc-unapproved = mkPrebootTest {
    name = "rc-unapproved";
    setup = writeRc {
      content = "--vcpu 1";
      approve = false;
    };
    expect = [ "new or changed" ];
  };

  runner-rc-changed = mkPrebootTest {
    name = "rc-changed";
    setup = ''
      ${writeRc { content = "--vcpu 1"; }}
      echo "--no-net-filter" > .llmjailrc
    '';
    expect = [ "new or changed" ];
  };

  runner-rc-unbalanced-quote = mkPrebootTest {
    name = "rc-unbalanced-quote";
    setup = writeRc { content = ''-- "oops''; };
    expect = [ "could not parse" ];
  };

  # After `--` it is the tool's argument, so the rc still needs approval.
  runner-rc-norc-tool-arg = mkPrebootTest {
    name = "rc-norc-tool-arg";
    setup = writeRc {
      content = "--vcpu 1";
      approve = false;
    };
    runnerArgs = [
      "--"
      "--norc"
    ];
    expect = [ "new or changed" ];
  };

  # Answers the prompt on a pty. The rc's --tmpdir makes the runner fail right
  # after applying it, so no VM boots: that error proves the rc was applied.
  runner-rc-prompt =
    pkgs.runCommand "llmjail-runner-rc-prompt"
      {
        nativeBuildInputs = [ pkgs.util-linux ];
      }
      ''
        ${prelude { }}
        ${writeRc {
          content = "--tmpdir /nonexistent";
          approve = false;
        }}
        approvals=$HOME/.config/llm-jail/approved-rc
        answer() {
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

        # Approving a changed rc replaces this directory's approval and no other.
        first_approval=$(cat "$approvals")
        subdir_approval="$(printf 'a%.0s' {1..64})  $PWD/sub"
        echo "$subdir_approval" >> "$approvals"
        ${writeRc {
          content = "--tmpdir /changed";
          approve = false;
        }}
        answer y
        grep -q "tmpdir '/changed' does not exist" "$TMPDIR/runner.log" || fail "changed rc was not applied"
        ! grep -Fxq -- "$first_approval" "$approvals" || fail "old approval was kept"
        grep -Fxq -- "$subdir_approval" "$approvals" || fail "approval of another directory was dropped"
        [ "$(wc -l < "$approvals")" = 2 ] || fail "expected the new approval and the other directory's"

        # So going back to the old content has to prompt again.
        ${writeRc {
          content = "--tmpdir /nonexistent";
          approve = false;
        }}
        rc=0
        ${shell}/bin/llm-jail-shell </dev/null >"$TMPDIR/runner.log" 2>&1 || rc=$?
        [ "$rc" = 1 ] || fail "runner exited with $rc, expected 1"
        grep -q "new or changed" "$TMPDIR/runner.log" || fail "old rc was still approved"

        touch $out
      '';

  # The workspace path ends up in ssh_config, where ssh expands % tokens.
  runner-reject-percent = mkPrebootTest {
    name = "reject-percent";
    workspace = "ws%x";
    expect = [ "must not contain '%'" ];
  };

  runner-reject-long-tmpdir = mkPrebootTest {
    name = "reject-long-tmpdir";
    setup = ''
      d=$(printf 'a%.0s' {1..100})
      mkdir "$TMPDIR/$d"
    '';
    rawArgs = ''--tmpdir "$TMPDIR/$d"'';
    expect = [ "socket path too long" ];
  };

  # ---------------------------------------------------------------------------
  # VM tests

  # Boots, root filesystems, shares, exit status, env handling, and a setup
  # failure.
  runner-boot = mkVmTest {
    name = "boot";
    testScript = _: ''
      # The overlay is mounted in the initrd, so its options keep the /sysroot prefix.
      store_overlay = r"^overlay overlay .*upperdir=/sysroot/\.nix-upper/store"

      with subtest("tmpfs root; env values are not executed by the guest"):
          log = jail("${sessionProbe}", env="ANTHROPIC_API_KEY='$(touch /workspace/pwned)'")
          expect(ws("root"), "^tmpfs rootfs rw", "root")
          expect(ws("store"), store_overlay, "store")
          expect(ws("share"), "^virtiofs ", "share")
          expect(ws("injected"), "No such file", "injected")
          clean_session(log)

      with subtest("disk root"):
          log = jail("${sessionProbe}", args="--disk 1")
          expect(ws("root"), "^ext4 /dev/vda rw", "root")
          expect(ws("store"), store_overlay, "store")
          clean_session(log)

      with subtest("exit status is passed through"):
          jail("${pkgs.writeShellScript "llmjail-probe-exit" "exit 7"}", expect_exit=7)

      with subtest("a failed setup unit powers the guest off before the session"):
          # The guest cannot create a mount point under /proc.
          log = jail("${sessionProbe}", setup="mkdir ~/extra", args="--mount $HOME/extra:/proc/llmjail", expect_exit=1)
          expect(log, r"--- guest\.log \(last 200 lines\) ---", "runner output")
    '';
  };

  # How .llmjailrc and the command line combine, as seen from the guest.
  runner-rc = mkVmTest {
    name = "rc";
    testScript = _: ''
      with subtest("rc and command line: the rc's -- does not swallow runner flags; quoting, nothing expanded"):
          rc = """--vcpu 1 --allow-domain rc.example \\
        -- 'single quoted' back\\ slash "" $HOME $(touch pwned)
      next-line"""
          jail("${rcProbe}", setup=rc_setup(rc), args="--vcpu 2 --allow-domain cli.example -- cli-arg")
          expect(ws("vcpus"), "^2$", "vcpus")
          expect(ws("tool-args"), r"^single quoted\|back slash\|\|\$HOME\|\$\(touch\|pwned\)\|next-line\|cli-arg\|$", "tool-args")
          expect(ws("domains"), r"^rc\.example$", "domains")
          expect(ws("domains"), r"^cli\.example$", "domains")
          expect(ws("injected"), "No such file", "injected")

      with subtest("rc: the command line's -- leaves the rc's flags in place"):
          jail("${rcProbe}", setup=rc_setup("--vcpu 1"), args="-- cli-arg")
          expect(ws("vcpus"), "^1$", "vcpus")
          expect(ws("tool-args"), r"^cli-arg\|$", "tool-args")

      with subtest("rc: empty file"):
          jail("${rcProbe}", setup=rc_setup(""), args="-- cli-arg")
          expect(ws("tool-args"), r"^cli-arg\|$", "tool-args")

      with subtest("--norc ignores an unapproved rc"):
          jail("${rcProbe}", setup=rc_setup("--vcpu 1 -- rc-arg", approve=False), args="--norc --vcpu 2 -- cli-arg")
          expect(ws("vcpus"), "^2$", "vcpus")
          expect(ws("tool-args"), r"^cli-arg\|$", "tool-args")
    '';
  };

  # Ctrl-C, the inspection shell, and that nothing outlives the run.
  runner-lifecycle = mkVmTest {
    name = "lifecycle";
    testScript = _: ''
      def as_alice(script):
          host.succeed(f"su - alice -c {shlex.quote(script)}")

      with subtest("Ctrl-C reaches only the runner's process group"):
          as_alice("""
            set -eu
            fail() { echo "FAIL: $1"; cat ~/runner.log; exit 1; }
            rm -rf ~/ws; mkdir ~/ws; cd ~/ws
            # --default-signal undoes the SIGINT ignore bash gives background jobs;
            # setsid makes the runner lead its own process group without forking.
            SHELL=${pkgs.writeShellScript "llmjail-probe-sleep" "touch started; sleep 60"} \\
              env --default-signal=INT setsid llm-jail-shell --mem 1024 </dev/null >~/runner.log 2>&1 &
            runner=$!
            for i in $(seq 9000); do
              [ -e started ] && break
              kill -0 $runner 2>/dev/null || fail "runner exited before the session started"
              sleep 0.1
            done
            [ -e started ] || fail "session did not start"
            # The anchors keep the ssh master, whose arguments contain the socat path, from matching.
            runner_sid=$(ps -o sid= -p $runner)
            for pat in '^qemu-system-[^ ]* .*/tmp/' '^[^ ]*/bin/socat - UNIX-CONNECT:/tmp/'; do
              pids=$(pgrep -f "$pat") || fail "no process matches /$pat/"
              [ "$(echo "$pids" | wc -l)" = 1 ] || fail "several processes match /$pat/: $pids"
              [ "$(ps -o sid= -p $pids)" != "$runner_sid" ] || fail "/$pat/ runs in the runner's session"
            done
            kill -INT -- -$runner
            timeout 60 tail --pid=$runner -f /dev/null || fail "runner did not exit within 60 s of SIGINT"
            rc=0; wait $runner || rc=$?
            [ $rc != 0 ] || fail "runner exited 0 after SIGINT"
            for msg in "VM did not power off within 15 s" "lost connection to VM"; do
              if grep -q "$msg" ~/runner.log; then fail "runner printed '$msg'"; fi
            done
          """)

      with subtest("no helper process outlives the run"):
          host.fail("pgrep -u alice -a 'qemu-system|virtiofsd|socat'")

      with subtest("the inspection shell runs as the session's user and ends with it"):
          for args, user in [("", "user")]:
              as_alice(f"""
                set -eu
                fail() {{ echo "FAIL: $1"; cat ~/runner.log; exit 1; }}
                rm -rf ~/ws; mkdir ~/ws; cd ~/ws
                SHELL=${pkgs.writeShellScript "llmjail-probe-wait" ''
                  for (( i=0; i < 600; i++ )); do
                    [ -e go ] && exit 0
                    sleep 0.1
                  done
                  exit 1
                ''} timeout 600 llm-jail-shell --mem 1024 {args} </dev/null >~/runner.log 2>&1 &
                runner=$!
                cmd=
                for i in $(seq 9000); do
                  cmd=$(sed -n 's/^To open a shell in this jail: //p' ~/runner.log)
                  [ -n "$cmd" ] && break
                  kill -0 $runner 2>/dev/null || fail "runner exited without printing the inspection command"
                  sleep 0.1
                done
                [ -n "$cmd" ] || fail "no inspection command"
                read -ra argv <<<"$cmd"
                rundir=$(dirname "''${{argv[2]}}")
                output=$("''${{argv[@]}}" id -un </dev/null) || fail "inspection command failed"
                [ "$output" = {user} ] || fail "inspection shell runs as '$output', expected {user}"
                [ "$(stat -c %a "$rundir")" = 700 ] || fail "$rundir is not mode 700"
                for f in id ssh_config; do
                  [ ! -e "$rundir/share/$f" ] || fail "$f is shared with the guest"
                done
                "''${{argv[@]}}" sleep 300 </dev/null &
                inspect=$!
                touch go
                rc=0; wait $runner || rc=$?
                [ $rc = 0 ] || fail "runner exited with $rc"
                for i in $(seq 25); do kill -0 $inspect 2>/dev/null || break; sleep 0.2; done
                if kill -0 $inspect 2>/dev/null; then fail "inspection shell outlived the tool session"; fi
              """)
    '';
  };
}
