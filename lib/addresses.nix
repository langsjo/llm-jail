# The jail's network addresses, shared by the guest config and lib/net.nix.
#
# The guest's NIC is a tap in a per-run network namespace. TEST-NET-1 is
# never routed on a real network, so it can't collide with the host's own
# networks, whose addresses pasta copies into that namespace.
{
  # The namespace's end of the tap: the guest's gateway and DNS server.
  gateway = "192.0.2.1";
  guest = "192.0.2.2";
  prefixLength = 24;
  # pasta forwards DNS queries sent here to the host's resolver. It is
  # link-local, so guest packets to it are refused.
  dnsForward = "169.254.53.53";
}
