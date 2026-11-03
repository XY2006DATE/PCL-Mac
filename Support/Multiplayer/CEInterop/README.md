# CE source interoperability fixture

This test-only console host links the user's PCL CE source files unchanged:
LobbyCodeGenerator, ScaffoldingClient/Server, binary framing, requests, handlers,
profile models and JsonCompat. It supplies only logging/application metadata,
a minimal server context and an unrelated date-regex dependency. No CE UI,
login, telemetry, private API, or Windows-only application services are run.
The CE source itself is not copied or distributed in the Mac app.

Requirements: .NET 10 SDK and the CE source tree. By default the source root is
`../PCL-CE` relative to this standalone repository. Run from the repository:

```sh
PCL_CE_DOTNET=/path/to/dotnet PCL_CE_SOURCE=/path/to/PCL-CE \
PCL_EASYTIER_TEST_DIR=/path/to/verified/macos/runtime \
zsh scripts/test-ce-interop.sh
```

Direct tests verify both control directions, lobby identity, port exchange,
CE's persistent client connection and heartbeat/profile decoding. Transport
tests additionally run EasyTier with the CE source's KCP/QUIC and p2p-only flags,
and verify real TCP and UDP payloads in both directions. The control endpoint,
game echo and independent discovery relay all run on loopback on one Mac.
This is source interoperability coverage, not a Windows/Internet gameplay test.

Only the test SDK uses disk space; it is never bundled with PCL Mac. Build
outputs go under `.build/ce-interop`. Normal Swift tests skip these opt-ins.
The fixture doesn't accept or use a real user's lobby code or game data.
