{ pkgs, ... }:

# Visible in-VM browser for the runner's --browser flag. Imported by
# common.nix for every tool, but inert at runtime unless llmjail.browser=1
# is on the kernel cmdline: the cage session is condition-gated, and the
# extra QEMU devices (virtio-vga, keyboard, tablet) only exist when the
# runner passed --browser. The QEMU GTK window then shows this cage session
# (a single maximized Chromium, no desktop environment) while the tool's
# TUI keeps running on /dev/hvc0. Harnesses reach the browser over CDP at
# http://127.0.0.1:9222 (loopback is always allowed by the net filter).

let
  # Harness-independent browser state (cookies, logins). The runner mounts
  # ~/.config/llm-jail/browser/<profile> here so sessions survive both VM
  # exits and switching tools.
  stateDir = "/home/user/.llmjail-browser";

  browserChromium = pkgs.writeShellScript "llmjail-browser-chromium" ''
    # Fallback for a caller that sets llmjail.browser=1 without the mount;
    # normally the runner's 9p mount already exists (and is chowned by
    # llmjail-mounts, which this session is ordered after).
    ${pkgs.coreutils}/bin/mkdir -p ${stateDir}

    # - A non-default --user-data-dir is required for Chromium to honor
    #   --remote-debugging-port at all (ignored on the default profile).
    # - No --remote-allow-origins: web pages can't drive the CDP socket;
    #   puppeteer-style clients send no Origin header and connect fine.
    # - --disable-quic: the net filter drops UDP 443, and QUIC-first
    #   connections would stall before falling back to TCP.
    # - --disable-gpu: render on CPU; the cage session composites with
    #   pixman (see WLR_RENDERER), so nothing needs GL on virtio-vga.
    exec ${pkgs.chromium}/bin/chromium \
      --user-data-dir=${stateDir} \
      --remote-debugging-port=9222 \
      --ozone-platform=wayland \
      --no-first-run \
      --no-default-browser-check \
      --password-store=basic \
      --hide-crash-restore-bubble \
      --disable-quic \
      --disable-gpu \
      --start-maximized
  '';
in
{
  # cage is a single-app Wayland kiosk. The module runs it on tty1 with a
  # PAM/logind session, which grants seat0 DRM+input access and an
  # XDG_RUNTIME_DIR without seatd or a display manager. It also enables
  # hardware.graphics (mesa) and sets the default target to graphical -
  # harmless for non-browser runs since graphical wants multi-user and the
  # session unit is condition-gated below.
  services.cage = {
    enable = true;
    user = "user";
    program = "${browserChromium}";
    # Software renderer: virtio-vga without virgl has no guest GL, and
    # pixman sidesteps llvmpipe/EGL entirely.
    environment.WLR_RENDERER = "pixman";
  };

  systemd.services."cage-tty1" = {
    # /dev/tty1 exists even without a GPU, so the module's own
    # ConditionPathExists doesn't gate anything - this does. Skipped (not
    # failed) on normal runs.
    unitConfig.ConditionKernelCommandLine = "llmjail.browser=1";
    # The browser state mount must be in place (and chowned) before
    # Chromium writes its profile. No ordering against llmjail-tool in
    # either direction: the TUI must not wait on Chromium, and harness CDP
    # retries absorb the startup race.
    after = [ "llmjail-mounts.service" ];
    wants = [ "llmjail-mounts.service" ];
    serviceConfig = {
      # The upstream module sets no Restart. If the user closes Chromium
      # the session should come back, not leave a dead window.
      Restart = "always";
      RestartSec = "2";
    };
  };

  # Fallback access paths for wlroots if the logind route ever fails; the
  # groups are meaningless outside the jail.
  users.users.user.extraGroups = [ "video" "input" ];

  # Autoloading via virtio_pci usually works; be explicit so the DRM device
  # is deterministically there when cage starts. No-ops without the device.
  boot.kernelModules = [ "virtio_gpu" "virtio_input" ];

  # Without any fonts every page renders as tofu.
  fonts.packages = [ pkgs.dejavu_fonts pkgs.liberation_ttf ];

  # Debuggability from the shell tool; also what harness-side headless
  # fallbacks (e.g. puppeteer's system-browser detection) find.
  environment.systemPackages = [ pkgs.chromium ];
}
