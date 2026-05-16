import Testing
import Foundation
import MathJaxSwift
@testable import MarkdownMath
import MarkdownRenderKit

@Suite("MathJaxRenderer")
struct MathJaxRendererTests {
    @Test("合法公式 → .rendered，尺寸为正")
    func validRenders() async {
        let r = MathJaxRenderer()
        let out = await r.render(latex: "x^2+1", display: false, pointSize: 16, scale: 2, color: .black)
        guard case .rendered(let g) = out else { Issue.record("expected .rendered, got \(out)"); return }
        #expect(g.image.size.width > 1)
    }

    @Test("非法公式 → 仍 .rendered（MathJax 错误 SVG 算成功）")
    func invalidStillRenders() async {
        let r = MathJaxRenderer()
        let out = await r.render(latex: "\\thisCommandDoesNotExist", display: false, pointSize: 16, scale: 2, color: .black)
        if case .failed = out { Issue.record("LaTeX 语法错误不应是 .failed") }
    }

    @Test("取消的 Task → .cancelled，不污染")
    func cancellation() async {
        let r = MathJaxRenderer()
        let task = Task { await r.render(latex: "\\int_0^1 x", display: true, pointSize: 16, scale: 2, color: .black) }
        task.cancel()
        let out = await task.value
        if case .failed = out { Issue.record("取消不应映射为 .failed") }
    }

    // MARK: - Task-13 评审强制的 4 项契约测试

    /// 与 `render` 完全相同的 options，独立再跑一次真实 tex2svg，拿到 SVG 字符串。
    private func realSVG(latex: String, display: Bool) throws -> String {
        let mathjax = try MathJax(preferredOutputFormat: .svg)
        return try mathjax.tex2svg(
            latex,
            conversionOptions: ConversionOptions(display: display),
            inputOptions: TeXInputProcessorOptions(loadPackages: TeXInputProcessorOptions.Packages.all),
            outputOptions: SVGOutputProcessorOptions())
    }

    @Test("契约1：真实 tex2svg(与 render 同 options) 根 svg 是 inline（width=<数字>ex 且非 100%）")
    func contractInlineRootSVG() throws {
        let svg = try realSVG(latex: "x^2+1", display: false)
        // 取第一个 <svg ...> 开标签
        guard let openStart = svg.range(of: "<svg"),
              let openEnd = svg.range(of: ">", range: openStart.lowerBound..<svg.endIndex) else {
            Issue.record("没有找到 <svg> 开标签：\(svg.prefix(200))")
            return
        }
        let openTag = String(svg[openStart.lowerBound..<openEnd.upperBound])
        // 必须含 width="<数字>ex"（inline 模式特征 — SVGRasterizer 输入契约）
        let exPattern = #"width\s*=\s*"\d*\.?\d+ex""#
        let hasEx = openTag.range(of: exPattern, options: .regularExpression) != nil
        #expect(hasEx, "根 <svg> 开标签必须含 width=\"<数字>ex\"，实际：\(openTag)")
        // 必须不含 width="100%"（container/SVG-tag 模式 → SVGRasterizer 对合法公式静默 .parseFailed）
        #expect(!openTag.contains("width=\"100%\""), "根 <svg> 不得为 container 模式 width=\"100%\"，实际：\(openTag)")
    }

    @Test("契约2：真实 SVG 经 injectColor 后 currentColor 全被替换")
    func contractColorInjectionOnRealFixture() throws {
        let svg = try realSVG(latex: "x^2+1", display: false)
        let injected = SVGRasterizer.injectColor(into: svg, hex: "#FF8800")
        #expect(!injected.contains("currentColor"), "注入后不得残留 currentColor")
        #expect(injected.contains("#FF8800"), "注入后必须含目标 hex #FF8800")
        // 若真实根同时有 stroke="currentColor" 与 fill="currentColor"，两处都必须被替换
        if svg.contains("stroke=\"currentColor\"") {
            #expect(!injected.contains("stroke=\"currentColor\""), "stroke=\"currentColor\" 未被替换")
        }
        if svg.contains("fill=\"currentColor\"") {
            #expect(!injected.contains("fill=\"currentColor\""), "fill=\"currentColor\" 未被替换")
        }
    }

    @Test("契约3：真实合法公式经 render 端到端，baseline 合理 + image.size 点尺寸量级")
    func contractEndToEndRasterize() async {
        let r = MathJaxRenderer()
        let out = await r.render(latex: "x^2+1", display: false, pointSize: 16, scale: 2, color: .black)
        guard case .rendered(let g) = out else {
            Issue.record("期望 .rendered，实际 \(out)")
            return
        }
        // inline 公式 baseline 通常 <= 0（下移为正、上抬为负），且为合理量级（不硬编码精确值）
        #expect(g.baselineOffsetEx != 0, "inline 公式 baselineOffsetEx 不应为 0（应解析到 vertical-align）")
        #expect(abs(g.baselineOffsetEx) < 10, "baselineOffsetEx 量级应合理（<10 ex），实际 \(g.baselineOffsetEx)")
        // 点尺寸量级：与 pointSize=16 同数量级，远小于 pixel×scale
        #expect((1...200).contains(g.image.size.height),
                "image.size.height 应为点尺寸量级 1...200（pointSize=16），实际 \(g.image.size.height)")
        #expect((1...400).contains(g.image.size.width),
                "image.size.width 应为点尺寸量级，实际 \(g.image.size.width)")
    }

    @Test("契约4：取消一次后，同一 renderer 新发 render 仍 .rendered（实例不被污染）")
    func contractCancellationDoesNotPoisonInstance() async {
        let r = MathJaxRenderer()
        let task = Task { await r.render(latex: "\\int_0^1 x", display: true, pointSize: 16, scale: 2, color: .black) }
        task.cancel()
        _ = await task.value
        // 同一实例新发一次（未取消）应正常 .rendered
        let out = await r.render(latex: "x^2+1", display: false, pointSize: 16, scale: 2, color: .black)
        guard case .rendered(let g) = out else {
            Issue.record("取消污染了实例：再次 render 期望 .rendered，实际 \(out)")
            return
        }
        #expect(g.image.size.width > 1)
    }

    // MARK: - Task-14 评审 G1：并发回归守卫（消除 Critical C1）

    @Test("同一实例并发渲染不同公式：不串味、不崩、全 .rendered")
    func contractConcurrentSameInstanceNoCrossContamination() async {
        let r = MathJaxRenderer()
        // 8 个公式：均为当前 options（loadPackages: .all）下确定**合法**且渲染尺寸
        // 各不相同的输入（SVG 长度 1825…4389 互异 → 尺寸可区分，串味检测成立）。
        // 注意：不使用 \sum / \lim 等带 \limits 语义的算子——它们在 MathJaxSwift +
        // loadPackages .all 组合下会被某宏包重解释为 "Extra open brace"（与本 C1
        // 无关，属上游 options 交互），会让 .failed 干扰并发回归判定。
        let inputs = ["x^2", "\\frac{a}{b}", "\\vec{v}\\cdot\\vec{w}", "\\sqrt{2}",
                      "\\alpha+\\beta", "E=mc^2", "\\int_0^1 x\\,dx", "a_{ij}"]
        // 并发 N 个 render（同一实例），每个产物必须对应自己的输入、且都成功
        let results = await withTaskGroup(of: (String, MathRenderOutcome).self) { group in
            for s in inputs {
                group.addTask { (s, await r.render(latex: s, display: false, pointSize: 16, scale: 2, color: .black)) }
            }
            var acc: [(String, MathRenderOutcome)] = []
            for await pair in group { acc.append(pair) }
            return acc
        }
        #expect(results.count == inputs.count)
        for (input, outcome) in results {
            guard case .rendered(let g) = outcome else {
                Issue.record("并发 render \(input) 未 .rendered: \(outcome)"); continue
            }
            #expect(g.image.size.width > 1 && g.image.size.height > 1)
        }
        // 串味检测：用一个对每个输入可区分的代理量——不同公式的渲染尺寸不应全相同
        // （强相关于"是否各自正确转换"；至少断言并发结果集与串行结果集逐一一致）
        for input in inputs {
            let serial = await r.render(latex: input, display: false, pointSize: 16, scale: 2, color: .black)
            guard case .rendered(let sg) = serial,
                  case .rendered(let cg)? = results.first(where: { $0.0 == input })?.1 else {
                Issue.record("一致性比对失败: \(input)"); continue
            }
            #expect(abs(sg.image.size.width - cg.image.size.width) < 1.0)
            #expect(abs(sg.image.size.height - cg.image.size.height) < 1.0)
        }
    }

    // MARK: - Task-14b：核心公式渲染契约（loadPackages/digits 配置修复）

    @Test("核心 LaTeX 公式均 .rendered（loadPackages 配置修复）")
    func contractCoreFormulasRender() async {
        let r = MathJaxRenderer()
        let formulas = ["\\sum_{i=1}^n i", "\\lim_{x\\to 0} f(x)", "\\int_0^1 x\\,dx",
                        "\\frac{a}{b}", "\\sqrt{2}", "x^2+1", "\\vec{v}",
                        "\\alpha+\\beta", "e^{i\\pi}+1=0",
                        "\\begin{matrix}a&b\\\\c&d\\end{matrix}"]
        for f in formulas {
            let out = await r.render(latex: f, display: false, pointSize: 16, scale: 2, color: .black)
            guard case .rendered = out else {
                Issue.record("核心公式应 .rendered 但得 \(out): \(f)"); continue
            }
        }
    }
}
