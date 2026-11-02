import XCTest
@testable import PCLCore

final class GlobalLauncherSettingsTests: XCTestCase {
    func testPersonalizationAndLaunchSettingsRoundTrip() throws {
        var settings = GlobalLauncherSettings()
        settings.visibility = "hide"
        settings.width = 1280; settings.height = 720
        settings.gameArguments = "--demo --server 'localhost'"
        settings.garbageCollector = "generational-zgc"
        settings.backgroundOpacity = 0.35; settings.backgroundBlur = 12
        settings.musicAuto = true; settings.musicPauseInGame = true
        try settings.validate()
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(GlobalLauncherSettings.self, from: data), settings)
    }

    func testInvalidImportedValuesAndArgumentsAreRejected() throws {
        let changes: [(inout GlobalLauncherSettings) -> Void] = [
            { $0.width = -1 }, { $0.height = 20000 }, { $0.opacity = 0 },
            { $0.musicVolume = .nan }, { $0.backgroundBlur = -1 },
            { $0.visibility = "quit" }, { $0.garbageCollector = "invalid" },
            { $0.gameArguments = "--server 'unfinished" }, { $0.title = "PCL\0" }
        ]
        for change in changes {
            var settings = GlobalLauncherSettings(); change(&settings)
            XCTAssertThrowsError(try settings.validate())
        }
    }
}
