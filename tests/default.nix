{ pkgs, nixpkgs, nixpkgs-rolling, claude-code, codex-cli, copilot-cli, opencode, omp, autolith ? null, pi-coding-agent ? null }:

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
        boot.initrd.postMountCommands = lib.mkForce "";

        # Provide mock envfs contents for the mounts service
        systemd.tmpfiles.rules = [
          "d /workspace 0755 user users -"
          "f /llmjail-env/env 0644 root root - HOME=/home/user"
          "f /llmjail-env/tool-args 0644 root root -"
          "f /llmjail-env/allowed-domains 0644 root root -"
        ];

        # Tool service will fail without credentials - prevent it from
        # blocking boot or powering off the VM.
        systemd.services.llmjail-tool = {
          wantedBy = lib.mkForce [ ];
          serviceConfig.ExecStopPost = lib.mkForce "";
        };

        virtualisation.memorySize = 1024;
      };

      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        with subtest("tool binary exists"):
            machine.succeed("test -x ${toolBinary}")

        with subtest("systemd services are defined"):
            machine.succeed("systemctl cat llmjail-mounts.service")
            machine.succeed("systemctl cat llmjail-net-filter.service")
            machine.succeed("systemctl cat llmjail-tool.service")
            machine.succeed("systemctl cat llmjail-winsize.service")

        with subtest("winsize service is running"):
            machine.succeed("systemctl is-active llmjail-winsize.service")

        with subtest("mounts service handles no-mounts case"):
            machine.succeed("systemctl is-active llmjail-mounts.service")

        with subtest("tool service has correct configuration"):
            output = machine.succeed(
                "systemctl show llmjail-tool.service -p User,WorkingDirectory"
            )
            assert "User=user" in output, f"Expected User=user in: {output}"
            assert "WorkingDirectory=!/workspace" in output, f"Expected WorkingDirectory=!/workspace in: {output}"

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

        with subtest("browser session is gated off by default"):
            machine.fail("systemctl is-active cage-tty1.service")
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
      boot.initrd.postMountCommands = lib.mkForce "";

      # Enable net filtering via kernel cmdline
      boot.kernelParams = lib.mkAfter [ "llmjail.net_filter=1" ];

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f+ /llmjail-env/allowed-domains 0644 root root - api.anthropic.com"
      ];

      systemd.services.llmjail-tool = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.ExecStopPost = lib.mkForce "";
      };

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

  # Boots the lightest guest with llmjail.browser=1 (the feature is
  # tool-agnostic) and checks the cage/Chromium session comes up with a
  # reachable CDP endpoint. The test driver runs headless; a virtio-vga
  # device still gives the guest the DRM node cage needs, no host display
  # required. Chromium under TCG (CI has no KVM) is slow, hence the
  # generous CDP timeout.
  browserTest = pkgs.testers.nixosTest {
    name = "llmjail-browser-smoke";

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
      boot.initrd.postMountCommands = lib.mkForce "";

      # Enable the browser session via kernel cmdline, like --browser does.
      boot.kernelParams = lib.mkAfter [ "llmjail.browser=1" ];

      # The runner normally 9p-mounts the browser state dir; stand it in
      # with a plain directory.
      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "d /home/user/.llmjail-browser 0755 user users -"
        "f /llmjail-env/env 0644 root root - HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f /llmjail-env/allowed-domains 0644 root root -"
      ];

      systemd.services.llmjail-tool = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.ExecStopPost = lib.mkForce "";
      };

      virtualisation.qemu.options = [
        "-device virtio-vga"
        "-device virtio-keyboard-pci"
        "-device virtio-tablet-pci"
      ];
      virtualisation.memorySize = 3072;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")

      with subtest("cage session starts"):
          machine.wait_for_unit("cage-tty1.service")

      with subtest("chromium is available"):
          machine.succeed("which chromium")

      with subtest("CDP endpoint comes up"):
          machine.wait_until_succeeds(
              "curl -sf http://127.0.0.1:9222/json/version", timeout=600
          )

      with subtest("chromium writes its profile to the state dir"):
          machine.succeed('test -n "$(ls -A /home/user/.llmjail-browser)"')
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

  browser-smoke = browserTest;
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
  autolith-smoke = mkSmokeTest {
    name = "autolith";
    guestModule = ../guests/autolith.nix;
    toolBinary = pkgs.lib.getExe autolith;
  };
}
