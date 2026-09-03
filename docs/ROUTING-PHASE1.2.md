# MilMit Secure v0.1.2 - Routing Phase 1.2

Implemented foundation:

- Route snapshot before changes
- Dedicated VPN routing table (220)
- Policy rule priority support
- Default route verification through `milmitxfrm0`
- Safer apply flow (verify tunnel before route changes)

Next:

- fwmark based split tunneling
- DNS apply/restore
- Kill switch firewall guard
- IPv6 policy handling
