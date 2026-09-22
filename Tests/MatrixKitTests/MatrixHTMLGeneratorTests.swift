import Foundation
import Testing

@testable import MatrixKit

@Suite("MatrixHTMLGenerator")
struct MatrixHTMLGeneratorTests {
    @Test("Plain text becomes a paragraph")
    func plainText() {
        #expect(MatrixHTMLGenerator.html(fromMarkdown: "hello") == "<p>hello</p>")
    }

    @Test("Inline styles map to HTML tags")
    func inlineStyles() {
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "**bold**")
                == "<p><strong>bold</strong></p>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "*italic*")
                == "<p><em>italic</em></p>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "~~struck~~")
                == "<p><del>struck</del></p>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "`code`")
                == "<p><code>code</code></p>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "hi *there*, **you**")
                == "<p>hi <em>there</em>, <strong>you</strong></p>")
    }

    @Test("Links become anchors, preserving matrix.to fragments")
    func links() {
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "[Woo](https://kagi.com)")
                == "<p><a href=\"https://kagi.com\">Woo</a></p>")
        #expect(
            MatrixHTMLGenerator.html(
                fromMarkdown:
                    "[alice](https://matrix.to/#/@alice:example.org)")
                == "<p><a href=\"https://matrix.to/#/@alice:example.org\">alice</a></p>")
    }

    @Test("Headings map to h1-h6")
    func headings() {
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "# Title")
                == "<h1>Title</h1>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "### Deep")
                == "<h3>Deep</h3>")
    }

    @Test("Lists become ul/ol with start for non-1 ordinals")
    func lists() {
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "- a\n- b")
                == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "1. a\n2. b")
                == "<ol>\n<li>a</li>\n<li>b</li>\n</ol>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "3. a\n4. b")
                == "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>")
    }

    @Test("Block quotes wrap inner paragraphs")
    func blockQuote() {
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "> quoted")
                == "<blockquote>\n<p>quoted</p>\n</blockquote>")
    }

    @Test("Fenced code keeps language class and newlines")
    func fencedCode() {
        #expect(
            MatrixHTMLGenerator.html(
                fromMarkdown: "```swift\nlet x = 1\n```")
                == "<pre><code class=\"language-swift\">let x = 1\n</code></pre>")
    }

    @Test("Thematic break becomes hr")
    func thematicBreak() {
        #expect(MatrixHTMLGenerator.html(fromMarkdown: "---") == "<hr />")
    }

    @Test("Soft breaks stay newlines; blocks join with newlines")
    func whitespace() {
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "line one\nline two")
                == "<p>line one\nline two</p>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "# Title\n\nbody")
                == "<h1>Title</h1>\n<p>body</p>")
    }

    @Test("Typed HTML and special chars are escaped literal")
    func escaping() {
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "<del>x</del>")
                == "<p>&lt;del&gt;x&lt;/del&gt;</p>")
        #expect(
            MatrixHTMLGenerator.html(fromMarkdown: "1 < 2 & 3 > 2")
                == "<p>1 &lt; 2 &amp; 3 &gt; 2</p>")
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
