import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct HomepageNode: Identifiable, Sendable {
    public let id: Int
    public var kind: String
    public var attributes: [String: String]
    public var text = ""
    public var children: [HomepageNode] = []
}

public enum CustomHomepage {
    public static func parse(_ data: Data) throws -> [HomepageNode] {
        guard data.count <= 2 * 1024 * 1024, var xml = String(data: data, encoding: .utf8) else { throw failure("主页必须是 2 MB 以内的 UTF-8 XAML 文件。") }
        guard !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw failure("主页不支持 DTD 或外部实体。") }
        xml = xml.replacingOccurrences(of: #"<\?xml[^?]*\?>"#, with: "", options: .regularExpression)
        xml = "<StackPanel xmlns:local=\"clr-namespace:PCL\" xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\">" + xml + "</StackPanel>"
        let parser = XMLParser(data: Data(xml.utf8)); let delegate = HomepageParser()
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else { throw delegate.failure ?? Self.failure(parser.parserError?.localizedDescription ?? "无效 XAML") }
        return delegate.root?.children ?? []
    }
    static func failure(_ message: String) -> Error { NSError(domain: "PCL.Homepage", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class HomepageParser: NSObject, XMLParserDelegate {
    var stack: [HomepageNode] = []
    var root: HomepageNode?
    var failure: Error?
    var count = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        count += 1
        guard count <= 5000, stack.count < 40 else { failure = CustomHomepage.failure("主页布局过于复杂。"); parser.abortParsing(); return }
        let kind = name.split(separator: ":").last.map(String.init) ?? name
        stack.append(HomepageNode(id: count, kind: kind, attributes: attributes))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
    }
}
