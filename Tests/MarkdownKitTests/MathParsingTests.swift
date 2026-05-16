import MarkdownCore
import Testing

@Suite("Math IR")
struct MathIRTests {
    @Test("math / mathBlock 节点可构造且 Equatable")
    func mathNodesEquatable() {
        #expect(InlineNode.math(latex: "x^2") == InlineNode.math(latex: "x^2"))
        #expect(InlineNode.math(latex: "x^2") != InlineNode.math(latex: "y"))
        #expect(BlockNode.mathBlock(latex: "\\int") == BlockNode.mathBlock(latex: "\\int"))
        #expect(BlockNode.mathBlock(latex: "\\int") != BlockNode.mathBlock(latex: "\\sum"))
    }
}
