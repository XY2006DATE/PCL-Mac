// Test-only host for the supplied PCL CE source. Network framing, requests,
// response parsing, heartbeat and server handlers are linked unchanged from CE.
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using PCL.Core.Link.Scaffolding;
using PCL.Core.Link.Scaffolding.Client;
using PCL.Core.Link.Scaffolding.Client.Models;
using PCL.Core.Link.Scaffolding.Client.Requests;
using PCL.Core.Link.Scaffolding.Server;
using PCL.Core.Link.Scaffolding.Server.Abstractions;

if (args[0] == "client") {
    int control = int.Parse(args[1]), expected = int.Parse(args[2]);
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
    var client = new ScaffoldingClient("127.0.0.1", control, "CE Guest", "ce-source-client", "PCL CE source fixture");
    await client.ConnectAsync(deadline.Token);
    var port = await client.SendRequestAsync(new GetServerPortRequest(), deadline.Token);
    if (port != expected) throw new Exception("Game port mismatch");
    var payload = Encoding.ASCII.GetBytes("CE source ping");
    var echoed = await client.SendRequestAsync(new PingRequest(payload), deadline.Token);
    if (!echoed.Span.SequenceEqual(payload)) throw new Exception("Ping mismatch");
    await Task.Delay(12000, deadline.Token);
    if (client.PlayerList is null || !client.PlayerList.Any(x => x.Kind == PlayerKind.HOST) || !client.PlayerList.Any(x => x.MachineId == "ce-source-client")) throw new Exception("Heartbeat/profile mismatch");
    Console.WriteLine("CE_CLIENT_CONTROL_AND_HEARTBEATS_PASSED");
    await client.DisposeAsync();
} else if (args[0] == "server") {
    int control = int.Parse(args[1]), game = int.Parse(args[2]);
    var code = File.ReadAllText(args[3]).Trim();
    if (!LobbyCodeGenerator.TryParse(code, out var lobby)) throw new Exception("CE rejected generated lobby code");
    var context = new FixtureContext(game, lobby);
    await using var server = new ScaffoldingServer(control, context);
    server.Start();
    Console.WriteLine("CE_SERVER_READY");
    await Task.Delay(TimeSpan.FromSeconds(100));
} else if (args[0] == "parse") {
    if (!LobbyCodeGenerator.TryParse(File.ReadAllText(args[1]).Trim(), out var lobby)) throw new Exception("Invalid lobby code");
    Console.WriteLine(JsonSerializer.Serialize(lobby));
}

sealed class FixtureContext : IServerContext {
    public ConcurrentDictionary<string, TrackedPlayerProfile> TrackedPlayers { get; } = new();
    public IReadOnlyList<PlayerProfile> PlayerProfiles => TrackedPlayers.Values.Select(x => x.Profile).ToList();
    public event Action<IReadOnlyList<PlayerProfile>>? PlayerProfilesPing;
    public void OnPlayerProfilesChanged() => PlayerProfilesPing?.Invoke(PlayerProfiles);
    public int MinecraftServerProt { get; }
    public LobbyInfo UserLobbyInfo { get; }
    public string PlayerName => "CE Host";
    public FixtureContext(int port, LobbyInfo lobby) {
        MinecraftServerProt = port; UserLobbyInfo = lobby;
        TrackedPlayers["ce-source-host"] = new TrackedPlayerProfile { Profile = new PlayerProfile { Name = PlayerName, MachineId = "ce-source-host", Vendor = "PCL CE source fixture", Kind = PlayerKind.HOST }, LastSeenUtc = DateTime.UtcNow };
    }
}

// Non-network application dependencies. Serialization itself links CE's exact
// JsonCompat.cs; only its application-wide regex and logging sink are supplied.
namespace PCL.Core.Logging {
    public static class LogWrapper {
        public static void Debug(params object?[] values) { }
        public static void Info(params object?[] values) { }
        public static void Warn(params object?[] values) { }
        public static void Error(params object?[] values) { }
    }
}
namespace PCL.Core.Utils {
    public static class RegexPatterns {
        public static readonly Regex Iso8601EndOfDay = new(@"[T ]24:00:00");
    }
}

namespace PCL.Core.App {
    public static class Basics { public const string VersionName = "source fixture"; }
    public static class Paths { public static string SharedLocalData => Path.GetTempPath(); }
}
namespace PCL.Core.Utils.Secret {
    public static class Identify { public const string LauncherId = "ce-source-host"; }
}
