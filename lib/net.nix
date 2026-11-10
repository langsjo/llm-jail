# llmjail-net: runs QEMU in a network namespace whose only way out is the
# jail's filter.
#
#   llmjail-net (--allow-domains FILE | --unfiltered) --log FILE -- QEMU...
#
#   --allow-domains FILE  allow HTTP(S) to the domains in FILE (one per line,
#                         subdomains included) and nothing else
#   --unfiltered          allow everything except the always-blocked ranges
#   --log FILE            dnsmasq's query log
#
# It re-executes itself under pasta, which creates a user and network
# namespace owned by the invoking user (no host privileges) and carries its
# traffic to host sockets. Inside, it creates the guest's tap `jail0`, loads
# the nftables filter, starts dnsmasq, and execs QEMU with no capabilities.
# The guest sees only frames on the tap: its own root can change its routes,
# addresses or resolver and still reaches nothing but this filter.
{ pkgs }:

let
  addr = import ./addresses.nix;
in
pkgs.writeShellApplication {
  name = "llmjail-net";
  runtimeInputs = with pkgs; [
    coreutils
    dnsmasq
    iproute2
    nftables
    passt
    util-linux
  ];
  text = ''
    # Inside the namespace, the re-executed helper gets a private first
    # argument (rather than an environment variable, which the caller's
    # environment could already carry) and the host's addresses.
    IN_NAMESPACE=0
    HOST_ADDRESSES=
    if [ "''${1:-}" = --in-namespace ]; then
      IN_NAMESPACE=1
      HOST_ADDRESSES=$2
      shift 2
    fi

    ALLOW_DOMAINS=
    UNFILTERED=0
    LOG=
    ARGS=("$@")
    while [ $# -gt 0 ]; do
      case "$1" in
        --allow-domains) ALLOW_DOMAINS=$2; shift 2 ;;
        --unfiltered) UNFILTERED=1; shift ;;
        --log) LOG=$2; shift 2 ;;
        --) shift; break ;;
        *) echo "llmjail-net: unknown option $1" >&2; exit 1 ;;
      esac
    done
    if [ -z "$LOG" ] || [ $# -eq 0 ] || { [ -z "$ALLOW_DOMAINS" ] && [ "$UNFILTERED" = 0 ]; }; then
      echo "usage: llmjail-net (--allow-domains FILE | --unfiltered) --log FILE -- QEMU..." >&2
      exit 1
    fi

    if [ "$IN_NAMESPACE" = 0 ]; then
      # Connections pasta makes for the namespace come from the host itself,
      # so they would reach host services on any host address. Only those
      # pasta copies into the namespace are local there (refused by the
      # input chain); the rest go into the blocked set. Addresses the host
      # gains later are not covered.
      HOST_ADDRESSES=$(ip -4 -o addr show | while read -r _ _ _ cidr _; do echo "''${cidr%/*}"; done | paste -sd, -)
      # pasta's defaults would let the namespace reach host loopback: through
      # the gateway address (--no-map-gw) and through host ports forwarded
      # into its own loopback (-T, -U). Nothing is forwarded inward (-t, -u).
      # pasta exits with QEMU and passes its exit status through.
      exec pasta --config-net --foreground --quiet \
        --tcp-ports none --udp-ports none --tcp-ns none --udp-ns none \
        --no-map-gw \
        --dns-forward ${addr.dnsForward} \
        -- "$0" --in-namespace "$HOST_ADDRESSES" "''${ARGS[@]}"
    fi

    ip link set lo up
    # Owned by uid 0 here, so QEMU can attach to it after dropping every capability.
    ip tuntap add dev jail0 mode tap user 0
    echo 1 > /proc/sys/net/ipv6/conf/jail0/disable_ipv6
    ip addr add ${addr.gateway}/${toString addr.prefixLength} dev jail0
    ip link set jail0 up
    echo 1 > /proc/sys/net/ipv4/ip_forward

    if [ "$UNFILTERED" = 1 ]; then
      GUEST_ACCEPT='meta nfproto ipv4 accept'
    else
      # Only addresses dnsmasq resolved for an allowed domain, on HTTP(S).
      GUEST_ACCEPT='ip daddr @allowed tcp dport { 80, 443 } accept'
    fi

    BLOCKED_HOST=
    if [ -n "$HOST_ADDRESSES" ]; then
      BLOCKED_HOST=", $HOST_ADDRESSES"
    fi

    # Guest traffic passes the forward chain (and the input chain for DNS);
    # dnsmasq's upstream queries are this namespace's only output.
    nft -f - <<NFT
    table inet llmjail {
      # Filled by dnsmasq with every address it resolves for an allowed
      # domain. No timeout: re-adding an element does not renew it, so
      # entries would expire under clients still using a cached answer.
      set allowed {
        type ipv4_addr
      }
      # Never reachable from the guest, filtered or not: "this network",
      # loopback, link-local (cloud metadata, pasta's DNS forwarder),
      # multicast and reserved, and the host's own addresses.
      set blocked {
        type ipv4_addr
        flags interval
        # The host addresses may overlap the ranges (127.0.0.1).
        auto-merge
        elements = { 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/3$BLOCKED_HOST }
      }
      # The guest may only ask dnsmasq. This also covers the host addresses
      # pasta copies into this namespace, which are local here.
      chain input {
        type filter hook input priority 0; policy accept;
        iifname "jail0" ip daddr ${addr.gateway} meta l4proto { tcp, udp } th dport 53 accept
        iifname "jail0" goto refuse
      }
      # The policy drop only meets traffic from outside: nothing out there
      # may open connections to the guest.
      chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        iifname "jail0" ip daddr @blocked goto refuse
        iifname "jail0" $GUEST_ACCEPT
        iifname "jail0" goto refuse
      }
      # Blocked guest traffic fails at once instead of hanging until the
      # client times out; the guest learns nothing it couldn't by waiting.
      chain refuse {
        meta l4proto tcp reject with tcp reset
        reject with icmpx admin-prohibited
      }
      chain postrouting {
        type nat hook postrouting priority 100;
        oifname != "jail0" masquerade
      }
    }
    NFT

    # Names outside the allowlist get REFUSED: there is no default upstream.
    DNSMASQ_ARGS=()
    if [ "$UNFILTERED" = 1 ]; then
      DNSMASQ_ARGS+=("--server=${addr.dnsForward}")
    else
      while IFS= read -r domain || [ -n "$domain" ]; do
        [ -z "$domain" ] && continue
        # In dnsmasq's /DOMAIN/ syntax `#` means every domain and `/` ends
        # the list, so only plain names get through.
        if [[ ! "$domain" =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$ ]]; then
          echo "llmjail-net: not a domain name: $domain" | cat -v >&2
          exit 1
        fi
        DNSMASQ_ARGS+=(
          "--server=/$domain/${addr.dnsForward}"
          "--nftset=/$domain/4#inet#llmjail#allowed"
        )
      done < "$ALLOW_DOMAINS"
    fi
    # Empty --user/--group: switching user fails here (setgroups is denied in
    # this namespace), and there is no other user to switch to. Its parent
    # becomes QEMU through the exec below, so it dies with QEMU.
    setpriv --pdeathsig KILL -- dnsmasq \
      --keep-in-foreground \
      --conf-file=/dev/null \
      --no-resolv \
      --no-hosts \
      --listen-address=${addr.gateway} \
      --bind-interfaces \
      --user= --group= \
      --pid-file= \
      --log-queries \
      --log-facility="$LOG" \
      "''${DNSMASQ_ARGS[@]+"''${DNSMASQ_ARGS[@]}"}" &

    exec setpriv --pdeathsig KILL --bounding-set=-all --inh-caps=-all --ambient-caps=-all -- "$@"
  '';
}
