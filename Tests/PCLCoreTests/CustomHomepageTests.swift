import XCTest
@testable import PCLCore

final class CustomHomepageTests: XCTestCase {
    func testOriginalXAMLFragmentWithNamespacePrefixAndMultipleCards() throws {
        let nodes = try CustomHomepage.parse(Data("""
        <local:MyCard Title="公告"><StackPanel><TextBlock Text="A &amp; B&#xA;第二行"/><local:MyButton Text="Wiki" EventType="打开网页" EventData="https://zh.minecraft.wiki/"/></StackPanel></local:MyCard>
        <local:MyCard Title="第二张"/>
        """.utf8))
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].kind, "MyCard")
        XCTAssertEqual(nodes[0].children[0].children[0].attributes["Text"], "A & B\n第二行")
        XCTAssertEqual(nodes[0].children[0].children[1].attributes["EventType"], "打开网页")
    }
    func testRejectsExternalEntitiesAndInvalidOrOverlyNestedXML() {
        for xml in ["<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><TextBlock>&a;</TextBlock>", "<local:MyCard>", String(repeating: "<StackPanel>", count: 41) + String(repeating: "</StackPanel>", count: 41)] {
            XCTAssertThrowsError(try CustomHomepage.parse(Data(xml.utf8)))
        }
        XCTAssertThrowsError(try CustomHomepage.parse(Data(repeating: 32, count: 2 * 1024 * 1024 + 1)))
    }
    func testSettingsBeforeAlignmentMigrateWithoutLosingValues() throws {
        let settings = try JSONDecoder().decode(GlobalLauncherSettings.self, from: Data("{\"title\":\"My PCL\",\"width\":1280,\"musicVolume\":0.8}".utf8))
        XCTAssertEqual(settings.title, "My PCL")
        XCTAssertEqual(settings.width, 1280)
        XCTAssertEqual(settings.musicVolume, 0.8)
        XCTAssertEqual(settings.downloadThreads, 64)
        XCTAssertEqual(settings.downloadSpeed, 42)
        XCTAssertEqual(settings.homeMode, "blank")
        try settings.validate()
    }
}

final class OriginalThemeColorTests: XCTestCase {
    func testOriginalDefaultThemeAndHueWrap() {
        let rgb = OriginalThemeColor.rgb(hue: 210, saturation: 85, lightness: 55)
        XCTAssertEqual(Int((rgb.0 * 255).rounded()), 18)
        XCTAssertEqual(Int((rgb.1 * 255).rounded()), 122)
        XCTAssertEqual(Int((rgb.2 * 255).rounded()), 225)
        let wrapped = OriginalThemeColor.rgb(hue: 570, saturation: 85, lightness: 55)
        XCTAssertEqual(wrapped.0, rgb.0); XCTAssertEqual(wrapped.1, rgb.1); XCTAssertEqual(wrapped.2, rgb.2)
    }
}
