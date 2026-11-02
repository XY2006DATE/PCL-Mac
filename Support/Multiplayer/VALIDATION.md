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

## Automatic discovery and Scaffolding follow-up

- Full regression: 316 tests, 302 passed, 14 opt-in tests skipped, zero failures.
- Real EasyTier tests: automatic host/guest without any shared server over local
  IPv4 interfaces; forced IPv6 loopback; TCP and UDP payload verification.
- Real Scaffolding room: an independent shared relay, AES-GCM host/guest identity,
  hostname-based control discovery, dynamic loopback control/game forwarding,
  binary port exchange, member registration/listing, TCP/UDP game payloads.
- The wire parser was compared to CE's big-endian framing and a fixed little-
  endian base-34 lobby code vector. An independent Python reference client kept
  one control socket open across 16 seconds of fragmented heartbeat requests.
- Catalog failure fallback, alternate catalog format, address validation,
  self-contained direct links, credential redaction and cancellation passed.
- An actual public EasyTier peer handshake succeeded using CE's published
  HTTPS discovery URL node2; several old TCP entry points were unavailable.
- Windows CE/HMCL applications on a separate device and Internet Minecraft
  gameplay remain unverified. Protocol/source compatibility is not a substitute
  for that acceptance test.

Installed build 14 was also checked through its UI with custom nodes left blank:
created a U/ lobby, connected to actual public discovery peers, closed it, and
joined an independent Python implementation of the Scaffolding host through a
public discovery entry point. Member names and real TCP/UDP game payloads matched;
leaving removed the forward listener. This reference fixture ran on the same Mac,
not on a Windows device. Disposable test rooms/processes were stopped afterward.

## Local game/forward port diagnostic follow-up (build 15)

Hosting checks the actual loopback game listener before resolving public nodes
or downloading a runtime. A refused game port now identifies the Minecraft port
and explains opening the current singleplayer world to LAN. Forward readiness
has a separate bounded retry and message; permission failures remain distinct.
The nonblocking socket probe reads SO_ERROR and closes only its own descriptor.

Six real TCP tests cover closed/refused game ports, listening game ports, delayed
forward listeners, forward deadlines and cancellation. On Darwin a bound but
non-listening socket drops SYNs, so the refusal fixture closes its reservation.
Full regression: 322 tests, 308 passed, 14 opt-in tests skipped, zero failures,
including all four real EasyTier integration cases and persistent control frames.

The signed universal build 15 was installed in /Applications and checked in its
UI: creating a room with unbound port 11464 immediately displayed the Minecraft
LAN-world instructions, with no generic local-port timeout or relay startup.

## Node retry and storage limits (build 16)

The launcher reads the pinned core's real connector status (0=connected,
1=disconnected, 2=connecting). Unsuccessful transport entries have an 8-second
startup grace; HTTPS discovery entries have 25 seconds for resolution/handshake.
They are then removed through the core's connector RPC, rather than merely hiding
warnings while the core keeps retrying. Failed probes cool down for
30/60/120/240/300 seconds; two healthy entries suspend spare probes. Loss of a
healthy entry resumes due probes automatically. Query failures do not mark every
entry dead, and cancellation terminates pending maintenance commands.

Logs are pipe-only: explicit --file-log-level off, isolated per-session working
directory, inherited RUST_LOG removed. Duplicate runtime warnings are coalesced
before scheduling UI work; at most four runtime output callbacks per second.
Each UI log entry is clipped around 2 KB; the tail has both a 200-entry and 64-KB
bound. Failed-session metadata owned by exited launcher PIDs is reclaimed at the
next room creation; active processes, unknown folders and game data are preserved.

Eight focused tests cover status decoding, real failure grace, increasing/capped
cooldowns, retaining healthy connections, recovery after loss, unsuccessful RPC
mutation handling, 10,000 repeated warnings, unique-message bursts, Unicode log
size/count caps and conservative abandoned-session cleanup. A real-core test
kept an independently handshaken local relay while removing a refused connector,
verified no log files in the working directory, and checked process termination.
All four existing real-core Minecraft TCP/UDP and Scaffolding cases also passed.
Full regression: 331 tests, 317 passed, 14 opt-in skipped, zero failures.
Universal arm64/x86_64 build completed and signed build 16 installed.
The multiplayer sidebar now contains only the multiplayer entry; settings remain
available through Settings > Multiplayer.

Installed-app validation used a disposable loopback listener, not a Minecraft
world or user save. With custom peers empty, build 16 established two actual
public discovery connections. Connector RPC initially reported two handshaken
entries plus three still-probing entries; a later check reported only the two
handshaken entries and zero failed/probing entries. The UI displayed public-node
labels and merged-log counters, with the 200-entry/64-KB/no-disk explanation.
No session log files were created. Closing the test room removed all session
metadata and EasyTier processes; the disposable listener was then stopped.
The original game-port field was restored and the log panel collapsed.
