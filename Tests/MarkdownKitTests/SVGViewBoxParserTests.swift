import Foundation
@testable import MarkdownRenderKit
import Testing

@Suite("SVGViewBoxParser")
struct SVGViewBoxParserTests {
    @Test func parsesIntegerViewBox() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="480" height="320" viewBox="0 0 480 320"></svg>"#
        let aspect = SVGViewBoxParser.parseAspect(from: svg)
        #expect(aspect != nil)
        #expect(abs((aspect ?? 0) - (320.0 / 480.0)) < 0.0001)   // h/w
    }

    @Test func parsesDecimalViewBox() {
        let svg = #"<svg viewBox="0 0 100.5 200.25"></svg>"#
        let aspect = SVGViewBoxParser.parseAspect(from: svg)
        #expect(aspect != nil)
        #expect(abs((aspect ?? 0) - (200.25 / 100.5)) < 0.0001)
    }

    @Test func returnsNilWhenViewBoxMissing() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="480" height="320"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)
    }

    @Test func returnsNilWhenViewBoxHasWrongNumberOfValues() {
        let svg = #"<svg viewBox="0 0 480"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)
    }

    @Test func returnsNilWhenViewBoxContainsNonNumeric() {
        let svg = #"<svg viewBox="0 0 abc 320"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)
    }

    @Test func returnsNilWhenWidthIsZero() {
        let svg = #"<svg viewBox="0 0 0 320"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)   // 防 division by zero
    }

    @Test func handlesSVGTagAfterXMLDeclaration() {
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        <svg viewBox="0 0 200 100" xmlns="http://www.w3.org/2000/svg"></svg>
        """
        let aspect = SVGViewBoxParser.parseAspect(from: svg)
        #expect(aspect != nil)
        #expect(abs((aspect ?? 0) - 0.5) < 0.0001)
    }

    @Test func bailsOutWhenSVGTagPastFirst4KB() {
        let padding = String(repeating: " ", count: 5000)
        let svg = padding + #"<svg viewBox="0 0 480 320"></svg>"#
        #expect(SVGViewBoxParser.parseAspect(from: svg) == nil)   // 性能上限契约
    }
}
