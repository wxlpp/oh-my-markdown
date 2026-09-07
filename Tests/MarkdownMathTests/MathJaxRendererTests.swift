import Foundation
import MarkdownCore
@testable import MarkdownMath
import MarkdownPlatformView
import MarkdownRenderKit
import MathJaxSwift
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("MathJaxRenderer")
@MainActor
struct MathJaxRendererTests {
    @Test func builtInConfigurationsAreStableAndResourceKeysCoverOutputInputs() {
        let math = MathRendererConfiguration(renderer: MathJaxRenderer())
        #expect(math.configurationID == MathRendererConfiguration(renderer: MathJaxRenderer()).configurationID)
        let svg = SVGRendererConfiguration(renderer: SwiftDrawSVGBlockRenderer())
        #expect(svg.configurationID == SVGRendererConfiguration(renderer: SwiftDrawSVGBlockRenderer()).configurationID)
        #expect(math.configurationID != svg.configurationID)
        let base = MathCacheKey(latex: "x", display: false, pointSize: 16, colorHex: "#000000", rasterScale: 2, configurationID: math.configurationID)
        let variations = [
            MathCacheKey(latex: "y", display: false, pointSize: 16, colorHex: "#000000", rasterScale: 2, configurationID: math.configurationID),
            MathCacheKey(latex: "x", display: true, pointSize: 16, colorHex: "#000000", rasterScale: 2, configurationID: math.configurationID),
            MathCacheKey(latex: "x", display: false, pointSize: 17, colorHex: "#000000", rasterScale: 2, configurationID: math.configurationID),
            MathCacheKey(latex: "x", display: false, pointSize: 16, colorHex: "#FF0000", rasterScale: 2, configurationID: math.configurationID),
            MathCacheKey(latex: "x", display: false, pointSize: 16, colorHex: "#000000", rasterScale: 3, configurationID: math.configurationID),
            MathCacheKey(latex: "x", display: false, pointSize: 16, colorHex: "#000000", rasterScale: 2, configurationID: .uniqueInstance()),
        ]
        #expect(variations.allSatisfy { $0 != base })
        #expect(Set(variations + [base]).count == 7)
        let svgKeys = [
            SVGBlockCacheKey(svg: "a", availableWidth: 100, rasterScale: 2, configurationID: svg.configurationID),
            SVGBlockCacheKey(svg: "b", availableWidth: 100, rasterScale: 2, configurationID: svg.configurationID),
            SVGBlockCacheKey(svg: "a", availableWidth: 101, rasterScale: 2, configurationID: svg.configurationID),
            SVGBlockCacheKey(svg: "a", availableWidth: 100, rasterScale: 3, configurationID: svg.configurationID),
            SVGBlockCacheKey(svg: "a", availableWidth: 100, rasterScale: 2, configurationID: .uniqueInstance()),
        ]
        #expect(Set(svgKeys).count == 5)
    }

    @Test("合法公式 → .rendered，尺寸为正")
    func validRenders() async {
        let r = MathJaxRenderer()
        let out = await r.render(latex: "x^2+1", display: false, pointSize: 16, scale: 2, colorHex: "#000000")
        guard case .rendered(let g) = out else { Issue.record("expected .rendered, got \(out)"); return }
        #expect(g.image.pointSize.width > 1)
    }

    @Test("非法公式 → 仍 .rendered（MathJax 错误 SVG 算成功）")
    func invalidStillRenders() async {
        let r = MathJaxRenderer()
        let out = await r.render(latex: "\\thisCommandDoesNotExist", display: false, pointSize: 16, scale: 2, colorHex: "#000000")
        if case .failed = out { Issue.record("LaTeX 语法错误不应是 .failed") }
    }

    @Test("取消的 Task → .cancelled，不污染")
    func cancellation() async {
        let r = MathJaxRenderer()
        let task = Task { await r.render(latex: "\\int_0^1 x", display: true, pointSize: 16, scale: 2, colorHex: "#000000") }
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
            outputOptions: SVGOutputProcessorOptions()
        )
    }

    @Test("契约1：真实 tex2svg(与 render 同 options) 根 svg 是 inline（width=<数字>ex 且非 100%）")
    func contractInlineRootSVG() throws {
        let svg = try realSVG(latex: "x^2+1", display: false)
        // 取第一个 <svg ...> 开标签
        guard let openStart = svg.range(of: "<svg"),
              let openEnd = svg.range(of: ">", range: openStart.lowerBound ..< svg.endIndex) else {
            Issue.record("没有找到 <svg> 开标签：\(svg.prefix(200))")
            return
        }
        let openTag = String(svg[openStart.lowerBound ..< openEnd.upperBound])
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
        let out = await r.render(latex: "x^2+1", display: false, pointSize: 16, scale: 2, colorHex: "#000000")
        guard case .rendered(let g) = out else {
            Issue.record("期望 .rendered，实际 \(out)")
            return
        }
        // inline 公式 baseline 通常 <= 0（下移为正、上抬为负），且为合理量级（不硬编码精确值）
        #expect(g.baselineOffsetEx != 0, "inline 公式 baselineOffsetEx 不应为 0（应解析到 vertical-align）")
        #expect(abs(g.baselineOffsetEx) < 10, "baselineOffsetEx 量级应合理（<10 ex），实际 \(g.baselineOffsetEx)")
        // 点尺寸量级：与 pointSize=16 同数量级，远小于 pixel×scale
        #expect(
            (1 ... 200).contains(g.image.pointSize.height),
            "image.size.height 应为点尺寸量级 1...200（pointSize=16），实际 \(g.image.pointSize.height)"
        )
        #expect(
            (1 ... 400).contains(g.image.pointSize.width),
            "image.size.width 应为点尺寸量级，实际 \(g.image.pointSize.width)"
        )
    }

    @Test("契约4：取消一次后，同一 renderer 新发 render 仍 .rendered（实例不被污染）")
    func contractCancellationDoesNotPoisonInstance() async {
        let r = MathJaxRenderer()
        let task = Task { await r.render(latex: "\\int_0^1 x", display: true, pointSize: 16, scale: 2, colorHex: "#000000") }
        task.cancel()
        _ = await task.value
        // 同一实例新发一次（未取消）应正常 .rendered
        let out = await r.render(latex: "x^2+1", display: false, pointSize: 16, scale: 2, colorHex: "#000000")
        guard case .rendered(let g) = out else {
            Issue.record("取消污染了实例：再次 render 期望 .rendered，实际 \(out)")
            return
        }
        #expect(g.image.pointSize.width > 1)
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
                group.addTask { await (s, r.render(latex: s, display: false, pointSize: 16, scale: 2, colorHex: "#000000")) }
            }
            var acc: [(String, MathRenderOutcome)] = []
            for await pair in group {
                acc.append(pair)
            }
            return acc
        }
        #expect(results.count == inputs.count)
        for (input, outcome) in results {
            guard case .rendered(let g) = outcome else {
                Issue.record("并发 render \(input) 未 .rendered: \(outcome)"); continue
            }
            #expect(g.image.pointSize.width > 1 && g.image.pointSize.height > 1)
        }
        // 串味检测：用一个对每个输入可区分的代理量——不同公式的渲染尺寸不应全相同
        // （强相关于"是否各自正确转换"；至少断言并发结果集与串行结果集逐一一致）
        for input in inputs {
            let serial = await r.render(latex: input, display: false, pointSize: 16, scale: 2, colorHex: "#000000")
            guard case .rendered(let sg) = serial,
                  case .rendered(let cg)? = results.first(where: { $0.0 == input })?.1 else {
                Issue.record("一致性比对失败: \(input)"); continue
            }
            #expect(abs(sg.image.pointSize.width - cg.image.pointSize.width) < 1.0)
            #expect(abs(sg.image.pointSize.height - cg.image.pointSize.height) < 1.0)
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
            let out = await r.render(latex: f, display: false, pointSize: 16, scale: 2, colorHex: "#000000")
            guard case .rendered = out else {
                Issue.record("核心公式应 .rendered 但得 \(out): \(f)"); continue
            }
        }
    }
}

@Suite("Math end to end")
@MainActor
struct MathEndToEndTests {
    @Test("MarkdownText 管线：解析→未命中占位→真实 renderer→命中出 attachment")
    func fullPipeline() async throws {
        let doc = MarkdownDocument(parsing: "Energy: $E=mc^2$\n\n$$\\sum_{i=1}^n i$$")
        var renderer = MaterializationFixture(style: .default)
        let first = renderer.render(doc.blocks)
        var payloads: [(String, Bool)] = []
        first.enumerateAttribute(.markdownMathSource, in: NSRange(location: 0, length: first.length)) { v, _, _ in
            if let p = v as? String, let sep = p.firstIndex(of: "\u{1F}") {
                payloads.append((String(p[p.index(after: sep)...]), p.first == "1"))
            }
        }
        #expect(payloads.contains(where: { $0.0 == "E=mc^2" && $0.1 == false }))
        #expect(payloads.contains(where: { $0.0 == "\\sum_{i=1}^n i" && $0.1 == true }))

        let mj = MathJaxRenderer()
        for (latex, display) in payloads {
            let pt = MathMetrics.effectivePointSize(
                textPointSize: RenderStyle.default.bodyFont.pointSize, mathScale: 1
            )
            let out = await mj.render(
                latex: latex,
                display: display,
                pointSize: pt,
                scale: 2,
                colorHex: MathMetrics.colorHex(RenderStyle.default.textColor)
            )
            guard case .rendered(let g) = out else { Issue.record("\(latex) not rendered"); continue }
            let key = MathCacheKey(
                latex: latex,
                display: display,
                pointSize: pt,
                colorHex: MathMetrics.colorHex(RenderStyle.default.textColor),
                rasterScale: 2,
                configurationID: .semantic(namespace: "test", version: 1)
            )
            renderer.math[key.latex] = try (g.image.materialize(), g.baselineOffsetEx * pt * 0.5)
        }
        let second = renderer.render(doc.blocks)
        var attachments = 0
        second.enumerateAttribute(.attachment, in: NSRange(location: 0, length: second.length)) { v, _, _ in
            if v is NSTextAttachment { attachments += 1 }
        }
        #expect(attachments == 2)
    }

    @Test("改 mathScale 后有效字号变、键变、需重渲染（不复用旧字形）")
    func mathScaleInvalidation() {
        var style = RenderStyle.default
        let base = style.bodyFont.pointSize
        let k1 = MathMetrics.effectivePointSize(textPointSize: base, mathScale: style.mathScale)
        style.mathScale = 2.0
        let k2 = MathMetrics.effectivePointSize(textPointSize: base, mathScale: style.mathScale)
        #expect(k1 != k2)
    }

    // G2：display:true 块级公式经真实 renderer → .rendered，尺寸/基线合理
    @Test("G2 块级 display 公式端到端 .rendered，尺寸点量级、基线合理")
    func g2BlockDisplayRenders() async {
        let mj = MathJaxRenderer()
        let out = await mj.render(
            latex: "\\sum_{i=1}^n i",
            display: true,
            pointSize: 16,
            scale: 2,
            colorHex: "#000000"
        )
        guard case .rendered(let g) = out else { Issue.record("block display 应 .rendered: \(out)"); return }
        #expect(g.image.pointSize.width > 1 && g.image.pointSize.height > 1)
        #expect((1 ... 400).contains(g.image.pointSize.height)) // 点量级，非 pixel×scale
        #expect(g.baselineOffsetEx <= 0.5) // 块级基线合理（通常 ~0 或负）
    }

    @Test("replacement cancels old MathJax work and admits the next configuration")
    func g3SetRendererNewGenerationIsolatesInflight() async {
        let coordinator = MathLoadCoordinator(cache: RenderedResourceCache())
        let first = MathRendererConfiguration(renderer: MathJaxRenderer(), configurationID: .uniqueInstance())
        coordinator.configure(first)
        let firstKey = MathCacheKey(latex: "x", display: false, pointSize: 16, colorHex: "#000000", rasterScale: 2, configurationID: first.configurationID)
        let oldTask = coordinator.load(firstKey, isCurrent: { true }, completed: {})
        let second = MathRendererConfiguration(renderer: MathJaxRenderer(), configurationID: .uniqueInstance())
        coordinator.configure(second)
        let nextKey = MathCacheKey(latex: "y^2", display: false, pointSize: 16, colorHex: "#000000", rasterScale: 2, configurationID: second.configurationID)
        await coordinator.load(nextKey, isCurrent: { true }, completed: {})?.value
        await oldTask?.value
        #expect(coordinator.publication(for: firstKey) == nil)
        #expect(coordinator.publication(for: nextKey) != nil)
    }
}
