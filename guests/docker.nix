# Rootless Docker, added by the `docker` build-time argument
# (`nix run .#claude.docker`).
#
# Rootless rather than the stock rootful daemon, whose socket is
# root-equivalent in the guest. That no longer weakens the jail (its network
# filter, masks and protected git files are enforced on the host), but it
# keeps a default run free of root. Container traffic leaves through
# slirp4netns and the guest's NIC, so the host's filter applies to it
# unchanged, and it resolves through the same nameserver (slirp4netns
# forwards DNS to the one in /etc/resolv.conf).
#
# The daemon is NixOS's rootless user unit, run by `user`'s systemd user
# manager, which lingering starts at boot.
{ pkgs, ... }:
{
  llmjail.extraAllowedDomains = [
    # Docker Hub: registry-1.docker.io and auth.docker.io (subdomains are
    # matched automatically), plus the blob hosts pulls are redirected to
    # (https://docs.docker.com/desktop/setup/allow-list/)
    "docker.io"
    "production.cloudfront.docker.com"
    "production.cloudflare.docker.com"
    "docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com"
  ];

  virtualisation.docker.rootless = {
    enable = true;
  };
  # The module adds docker itself, which includes the compose and buildx CLI
  # plugins; this adds the standalone `docker-compose` command.
  environment.systemPackages = [ pkgs.docker-compose ];

  # The module's setSocketVariable derives the socket from XDG_RUNTIME_DIR,
  # which is not guaranteed in every context. set-environment is sourced by the
  # launcher and login shells, so $UID expands to the remapped uid there.
  environment.variables.DOCKER_HOST = "unix:///run/user/$UID/docker.sock";

  users.users.user = {
    # newuidmap/newgidmap map these into the daemon's user namespace
    autoSubUidGidRange = true;
    linger = true;
  };

  # linger-users starts user@<uid>, and with it the daemon. It resolves `user`
  # to a uid when it does, so it must run after the remap to the host uid.
  systemd.services.linger-users = {
    after = [ "llmjail-set-user-uid.service" ];
  };

  # user@<uid> reports ready at the user manager's basic.target, before the
  # daemon (in default.target) is up. Hold the session back until the socket
  # exists so `docker` works from its first command; a daemon that never
  # comes up delays the session by at most the timeout.
  systemd.services.llmjail-docker-ready = {
    description = "Wait for the rootless Docker socket";
    wantedBy = [ "multi-user.target" ];
    after = [ "linger-users.service" ];
    before = [ "llmjail-ready.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "30s";
    };
    script = ''
      sock="/run/user/$(id -u user)/docker.sock"
      until [ -S "$sock" ]; do sleep 0.1; done
    '';
  };

  # wants, not requires: a daemon that misses the timeout delays the session
  # but does not block it.
  systemd.targets.llmjail-ready = {
    wants = [ "llmjail-docker-ready.service" ];
    after = [ "llmjail-docker-ready.service" ];
  };
}
