# Multiplayer helper

`PCLLinkSupervisor.c` starts exactly one EasyTier process and watches its launcher
parent with `kqueue`. A normal stop or unexpected launcher exit sends SIGTERM to
that child, waits up to two seconds, and then kills only that child if necessary.
No service, administrator access, system networking changes or process-name
termination is used. Both the Xcode and shell builds include a universal helper.

The Swift runtime installer downloads the unmodified EasyTier 2.6.4 official
macOS release for the running architecture and verifies a pinned archive SHA-256.
Only `easytier-core` and `easytier-cli` are extracted. Its cache is under the
application support directory, separate from Minecraft instances.

Protocol reference: https://github.com/Meloong-Git/PCL/wiki/简洁联机标记约定

The default automatic mode independently implements the public Scaffolding
lobby code, framing, member heartbeat and game port exchange used by PCL CE,
HMCL and FCL. It uses AES-GCM, host address 10.114.51.41, a loopback control
listener, and only whitelists that control port and the game port. It fetches
public discovery catalogs and shares the public discovery URLs used by CE.
No official private launcher configuration API is called.

Two optional modes remain: PCL v02 custom-node invitations (02000, chacha20),
and Mac-only PCLM1 links that carry validated discovery/direct addresses. The
latter can connect through reachable IPv6 or a LAN without a shared server.
Neither format is represented as a Scaffolding code.

Protocol references:
- https://github.com/PCL-Community/PCL-CE/tree/67f540d0e32404d3b18d7d71db955dc8e0785f6b/PCL.Core/Link/Scaffolding
- https://github.com/Meloong-Git/PCL/wiki/简洁联机标记约定
- https://github.com/ldoubil/astral.github.io/blob/main/src/data/server.json

Management RPC, Scaffolding control and game forwards are loopback-only.
The mesh listeners use dynamically allocated TCP/UDP ports with IPv6 enabled.
The runtime uses no TUN or system DNS/route changes; it follows the existing
system route rather than forcing a physical interface.

Integration validation is opt-in; see `MultiplayerIntegrationTests.swift`.
Use disposable verified runtimes and loopback fixtures, never a user's game files.
