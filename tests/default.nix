{ pkgs, nixpkgs, nixpkgs-rolling, claude-code, codex-cli, copilot-cli, opencode, omp, autolith ? null, pi-coding-agent ? null, shell }:

let
  mkSmokeTest = { name, guestModule, toolBinary }:
    pkgs.testers.nixosTest {
      name = "llmjail-${name}-smoke";

      nodes.machine = { lib, ... }: {
        imports = [ guestModule ];
        _module.args = { inherit nixpkgs nixpkgs-rolling claude-code codex-cli copilot-cli opencode omp autolith pi-coding-agent; };
        # Override 9p filesystem entries from common.nix - the test framework
        # provides its own root and /nix/store via virtualisation options.
        fileSystems."/.nix-lower/store" = lib.mkForce {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "size=1M" ];
        };
        fileSystems."/llmjail-env" = lib.mkForce {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "size=10M" ];
        };

        # Provide mock envfs contents for the mounts service
        systemd.tmpfiles.rules = [
          "d /workspace 0755 user users -"
          "f /llmjail-env/env 0644 root root - export HOME=/home/user"
          "f /llmjail-env/tool-args 0644 root root -"
          "f /llmjail-env/allowed-domains 0644 root root -"
          "f /llmjail-env/authorized_keys 0644 root root - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST test"
        ];

        # The test VM has no llmjail.ssh port; the unit would wait for the
        # device and then power the VM off.
        systemd.services.llmjail-sshd.wantedBy = lib.mkForce [ ];

        virtualisation.memorySize = 1024;
      };

      testScript = { nodes, ... }: ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        with subtest("tool binary and launcher exist"):
            machine.succeed("test -x ${toolBinary}")
            machine.succeed("test -x ${nodes.machine.config.llmjail.launcher}")

        with subtest("setup units are done and the session gate is open"):
            machine.succeed("systemctl is-active llmjail-mounts.service")
            machine.succeed("systemctl is-active llmjail-net-filter.service")
            machine.succeed("systemctl is-active llmjail-ready.target")

        with subtest("sshd allows only key login as user"):
            # lower(): newer OpenSSH prints the keywords in CamelCase
            output = machine.succeed("sshd -T -f /etc/ssh/sshd_config").lower()
            for line in ["passwordauthentication no", "permitrootlogin no", "allowusers user", "permituserrc no"]:
                assert line in output.splitlines(), f"Expected '{line}' in sshd -T output: {output}"
            keyfile = [l for l in output.splitlines() if l.startswith("authorizedkeysfile")]
            assert keyfile and ".ssh/authorized_keys" not in keyfile[0], f"Unexpected authorizedkeysfile: {keyfile}"

        with subtest("authorized key is installed root-owned and read-only"):
            output = machine.succeed("stat -c '%a %U' /etc/ssh/authorized_keys.d/user")
            assert output.strip() == "444 root", f"Unexpected mode/owner: {output}"

        with subtest("sshd listens nowhere inside the guest"):
            machine.fail("systemctl is-active sshd.service")
            tcp = [l for l in machine.succeed("ss -Htln").splitlines() if not l.split()[3].endswith(":53")]
            assert not tcp, f"Unexpected TCP listeners: {tcp}"
            output = machine.succeed("ss -Hlxp")
            assert "sshd" not in output, f"Unexpected sshd unix listener: {output}"
            output = machine.succeed("systemctl list-units --all --plain --no-legend --state=active,listening 'sshd-*.socket'")
            assert output.strip() == "", f"Unexpected ssh generator sockets: {output}"

        with subtest("failures power the VM off"):
            for unit in ["llmjail-mounts", "llmjail-net-filter"]:
                output = machine.succeed(f"systemctl show -p FailureAction {unit}.service")
                assert output.strip() == "FailureAction=poweroff-force", f"{unit}: {output}"
            output = machine.succeed("systemctl show -p ExecStopPost llmjail-sshd.service")
            assert "poweroff" in output, f"Expected poweroff in ExecStopPost: {output}"

        with subtest("common packages are available"):
            machine.succeed("which git")
            machine.succeed("which node")
            machine.succeed("which curl")
            machine.succeed("which ssh")

        with subtest("user account is configured"):
            machine.succeed("id user")
            machine.succeed("test -d /home/user")
            machine.succeed("getent passwd user | grep -q /home/user")

        with subtest("nix has flakes enabled"):
            machine.succeed("nix --version")
            machine.succeed("nix eval --expr 'true'")

        with subtest("nixpkgs is pinned in registry and search path"):
            machine.succeed("cat /etc/nix/registry.json | grep nixpkgs")
            machine.succeed("nix-instantiate --eval -E '<nixpkgs>'")
        with subtest("user can read kernel journal"):
            machine.succeed("su - user -c 'journalctl -k --no-pager -n 1'")
      '';
    };

  netFilterTest = pkgs.testers.nixosTest {
    name = "llmjail-net-filter-smoke";

    nodes.machine = { lib, ... }: {
      imports = [ ../guests/claude.nix ];
      _module.args = { inherit nixpkgs nixpkgs-rolling claude-code codex-cli; };

      fileSystems."/.nix-lower/store" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=1M" ];
      };
      fileSystems."/llmjail-env" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=10M" ];
      };

      # Enable net filtering via kernel cmdline
      boot.kernelParams = lib.mkAfter [ "llmjail.net_filter=1" ];

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - export HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f+ /llmjail-env/allowed-domains 0644 root root - api.anthropic.com"
      ];

      systemd.services.llmjail-sshd.wantedBy = lib.mkForce [ ];

      virtualisation.memorySize = 1024;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("llmjail-net-filter.service")

      with subtest("dnsmasq is running"):
          machine.succeed("pgrep dnsmasq")

      with subtest("resolv.conf points to localhost"):
          output = machine.succeed("cat /etc/resolv.conf")
          assert "127.0.0.1" in output, f"Expected 127.0.0.1 in resolv.conf: {output}"

      with subtest("nftables rules are loaded"):
          output = machine.succeed("nft list ruleset")
          assert "llmjail_filter" in output, f"Expected llmjail_filter in nft rules: {output}"

      with subtest("dnsmasq config has allowed domain"):
          output = machine.succeed("cat /etc/dnsmasq-llmjail.conf")
          assert "api.anthropic.com" in output, f"Expected api.anthropic.com in dnsmasq config: {output}"

      with subtest("blocked domain fails to resolve"):
          machine.fail("getent hosts evil.example.com")
    '';
  };

  # Offline: loads a locally built image instead of pulling from Docker Hub.
  dockerTestImage = pkgs.dockerTools.buildLayeredImage {
    name = "llmjail-test";
    tag = "latest";
    contents = [ pkgs.busybox ];
    config.Cmd = [ "/bin/sh" "-c" "echo hello-from-container" ];
  };

  dockerTest = pkgs.testers.nixosTest {
    name = "llmjail-docker-smoke";

    nodes.machine = { lib, ... }: {
      imports = [ ../guests/claude.nix ../guests/docker.nix ];
      _module.args = { inherit nixpkgs nixpkgs-rolling claude-code; };

      fileSystems."/.nix-lower/store" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=1M" ];
      };
      fileSystems."/llmjail-env" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=10M" ];
      };

      # Remap `user` like the runner does for a host uid other than 1000, so
      # the daemon has to start under the remapped uid
      boot.kernelParams = lib.mkAfter [ "llmjail.user_uid=1234" ];

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - export HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f /llmjail-env/allowed-domains 0644 root root -"
      ];

      systemd.services.llmjail-sshd.wantedBy = lib.mkForce [ ];

      virtualisation.memorySize = 1536;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("llmjail-docker-ready.service")

      with subtest("daemon is rootless and runs under the remapped uid"):
          machine.wait_for_unit("docker.service", "user")
          output = machine.succeed("su - user -c 'docker info --format {{.SecurityOptions}}'")
          assert "rootless" in output, f"Expected rootless daemon: {output}"
          machine.succeed("pgrep -u 1234 -x dockerd")
          machine.fail("pgrep -u root -x dockerd")
          output = machine.succeed("su - user -c 'echo $DOCKER_HOST'")
          assert output.strip() == "unix:///run/user/1234/docker.sock", f"Unexpected DOCKER_HOST: {output}"

      with subtest("user can run a container"):
          machine.succeed("su - user -c 'docker load < ${dockerTestImage}'")
          output = machine.succeed("su - user -c 'docker run --rm llmjail-test:latest'")
          assert "hello-from-container" in output, f"Unexpected container output: {output}"

      with subtest("memory limits are enforced"):
          output = machine.succeed(
              "su - user -c 'docker run --rm --memory 64m llmjail-test:latest cat /sys/fs/cgroup/memory.max'"
          )
          assert output.strip() == "67108864", f"Unexpected memory.max: {output}"

      with subtest("compose plugin is available"):
          machine.succeed("su - user -c 'docker compose version'")
    '';
  };

  # A setup unit that fails must power the VM off instead of opening a session.
  failFastTest = pkgs.testers.nixosTest {
    name = "llmjail-fail-fast-smoke";

    nodes.machine = { lib, ... }: {
      imports = [ ../guests/shell.nix ];
      _module.args = { inherit nixpkgs nixpkgs-rolling; };

      fileSystems."/.nix-lower/store" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=1M" ];
      };
      fileSystems."/llmjail-env" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=10M" ];
      };

      # A share whose tag QEMU does not provide makes llmjail-mounts fail.
      boot.kernelParams = lib.mkAfter [ "llmjail.mounts=nosuchtag:/x:rw" ];

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - export HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f /llmjail-env/allowed-domains 0644 root root -"
      ];

      systemd.services.llmjail-sshd.wantedBy = lib.mkForce [ ];

      virtualisation.memorySize = 1024;
    };

    testScript = ''
      machine.start()
      machine.wait_for_console_text("Failed to start .*llmjail host shares")
      machine.wait_for_shutdown()
    '';
  };

in
{
  claude-smoke = mkSmokeTest {
    name = "claude";
    guestModule = ../guests/claude.nix;
    toolBinary = "${claude-code}/bin/claude";
  };

  codex-smoke = mkSmokeTest {
    name = "codex";
    guestModule = ../guests/codex.nix;
    toolBinary = "${codex-cli}/bin/codex";
  };

  copilot-smoke = mkSmokeTest {
    name = "copilot";
    guestModule = ../guests/copilot.nix;
    toolBinary = pkgs.lib.getExe copilot-cli;
  };

  opencode-smoke = mkSmokeTest {
    name = "opencode";
    guestModule = ../guests/opencode.nix;
    toolBinary = pkgs.lib.getExe opencode;
  };

  pi-smoke = mkSmokeTest {
    name = "pi";
    guestModule = ../guests/pi.nix;
    toolBinary = pkgs.lib.getExe pi-coding-agent;
  };

  omp-smoke = mkSmokeTest {
    name = "omp";
    guestModule = ../guests/omp.nix;
    toolBinary = pkgs.lib.getExe omp;
  };

  net-filter-smoke = netFilterTest;

  docker-smoke = dockerTest;

  fail-fast-smoke = failFastTest;
}
// import ./runner.nix { inherit pkgs shell; }
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
  autolith-smoke = mkSmokeTest {
    name = "autolith";
    guestModule = ../guests/autolith.nix;
    toolBinary = pkgs.lib.getExe autolith;
  };
}
