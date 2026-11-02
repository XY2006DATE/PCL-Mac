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

The first phase implements v02 custom-node invitations (`02000`). It does not
fetch private official PCL node configuration or implement CE's Scaffolding.
The core management RPC and game forward listen only on IPv4 loopback; mesh
listeners use dynamically reserved TCP/UDP ports. The core is configured with
no TUN and the internal network stack, so no system route/DNS changes are needed.

Integration validation is opt-in; see `MultiplayerIntegrationTests.swift`.
Use disposable verified runtimes and loopback fixtures, never a user's game files.
