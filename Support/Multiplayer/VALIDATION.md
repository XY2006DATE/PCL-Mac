# Phase 1 validation — 2026-11-03

- Full suite: 302 tests, 290 passed, 12 existing opt-in game/network tests skipped,
  zero failures. Multiplayer integration was enabled with verified official
  EasyTier 2.6.4 binaries and a disposable local shared relay.
- Both official macOS architectures passed real host/guest room discovery and
  TCP/UDP payload round trips. Apple Silicon ran natively; the Intel runtime ran
  under Rosetta on the same Mac. Neither test used a system TUN or elevated rights.
- The relay used a different network identity, exercising shared-node discovery
  rather than assuming all three peers already belong to the same room.
- The app's HTTPS transport fetched an actual official release range and matched
  its bytes against the verified archive. Fixture tests covered interrupted chunk
  retries, reuse of completed chunks, and rejection of incorrect Content-Range.
- Official ZIP installation, cache reuse, tamper rejection, atomic cache repair,
  and rejection of a modified ZIP were checked for both runtime architectures.
- Killing a disposable launcher parent stopped the supervisor's child process.
- Installed build 13: created and closed a room, joined and left a separate
  protocol fixture, and verified real TCP data through its displayed localhost
  address. Leaving removed the listener. Temporary test nodes were cleared.
- The app and helper were built for arm64 and x86_64. The installed app passed
  strict deep signature verification with the existing Developer ID identity.

Not yet verified: a separate Windows machine running original PCL, actual
Minecraft gameplay across two machines, Internet NAT traversal under different
networks, public-node availability, and CE/Scaffolding interoperability. Local
fixture results must not be described as a completed Mac/Windows gameplay test.

Reproduction commands are in the repository README and the test file headers.
No test uses or modifies Minecraft saves, mods, accounts or a user's instances.
