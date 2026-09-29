import Foundation
import Testing

@testable import MatrixKit

@Suite("MatrixHTMLGenerator")
struct MatrixHTMLGeneratorTests {
    @Test("Markdown maps to Matrix HTML", arguments: [
        ("hello", "<p>hello</p>"),
        ("**bold**", "<p><strong>bold</strong></p>"),
        ("*italic*", "<p><em>italic</em></p>"),
        ("~~struck~~", "<p><del>struck</del></p>"),
        ("`code`", "<p><code>code</code></p>"),
        ("hi *there*, **you**", "<p>hi <em>there</em>, <strong>you</strong></p>"),
        ("[Woo](https://kagi.com)", #"<p><a href="https://kagi.com">Woo</a></p>"#),
        (
            "[alice](https://matrix.to/#/@alice:example.org)",
            #"<p><a href="https://matrix.to/#/@alice:example.org">alice</a></p>"#
        ),
        ("# Title", "<h1>Title</h1>"),
        ("### Deep", "<h3>Deep</h3>"),
        ("- a\n- b", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>"),
        ("1. a\n2. b", "<ol>\n<li>a</li>\n<li>b</li>\n</ol>"),
        ("3. a\n4. b", "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>"),
        ("> quoted", "<blockquote>\n<p>quoted</p>\n</blockquote>"),
        (
            "```swift\nlet x = 1\n```",
            "<pre><code class=\"language-swift\">let x = 1\n</code></pre>"
        ),
        ("---", "<hr />"),
        ("line one\nline two", "<p>line one<br />line two</p>"),
        ("test\ntest\ntest", "<p>test<br />test<br />test</p>"),
        ("# Title\n\nbody", "<h1>Title</h1>\n<p>body</p>"),
        // Typed HTML and special chars escape to literals.
        ("<del>x</del>", "<p>&lt;del&gt;x&lt;/del&gt;</p>"),
        ("1 < 2 & 3 > 2", "<p>1 &lt; 2 &amp; 3 &gt; 2</p>"),
    ])
    func markdownToHTML(markdown: String, expected: String) {
        #expect(MatrixHTMLGenerator.html(fromMarkdown: markdown) == expected)
    }

    @Test("Markdown factory pairs raw body with HTML formatted body")
    func markdownFactory() {
        let content = MessageContent.markdown("hi *there*")
        #expect(content.msgtype == .text)
        #expect(content.body == "hi *there*")
        #expect(content.formattedBody == "<p>hi <em>there</em></p>")
        #expect(content.format == "org.matrix.custom.html")
    }

    @Test("Markdown edit repeats full formatted content in m.new_content")
    func markdownEdit() throws {
        let eventId = EventId(unchecked: "$x:example.com")
        let edit = EditContent.markdown(editing: eventId, "new *text*")
        #expect(edit.body == " * new *text*")
        #expect(edit.newContent.body == "new *text*")
        #expect(
            edit.newContent.formattedBody == "<p>new <em>text</em></p>")
        let data = try JSONEncoder().encode(edit)
        let json = try JSONDecoder().decode(
            [String: AnyCodable].self, from: data)
        #expect(
            json["m.new_content"]?["formatted_body"]?.stringValue
                == "<p>new <em>text</em></p>")
        #expect(json["m.relates_to"]?["rel_type"]?.stringValue == "m.replace")
    }
}
