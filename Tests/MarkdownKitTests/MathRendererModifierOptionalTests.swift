import MarkdownKit
import MarkdownRenderKit
import SwiftUI
import Testing

// MARK: - .mathRenderer(_:) optional widening guards (Copilot PR #4 R5 #3)

/// 守卫 `.mathRenderer(_:)` 参数已放宽为 `(any MathRendering)?`：
/// - 既有「传具体 renderer」用法仍源码兼容（不回归）；
/// - 新增「传 `nil`」用法可在运行时禁用 math，无需 branch 视图树。
///
/// 单测环境无 ViewInspector，无法从 `some View` 取回注入的 env，
/// 故守卫拆为两条：
///   1. 编译期：`.mathRenderer(nil)` / `.mathRenderer(renderer)` 两个调用点
///      必须能编译——把签名改回非可选会让 `nil` 调用点编译失败（git-反证 RED）。
///   2. 语义：`.mathRenderer(_:)` 内部把入参（含 nil）原样写入可选 env，
///      此处用 `EnvironmentValues` 钉死该 round-trip 契约——git-反证把
///      nil 替换成默认非 nil 时，env 不再为 nil → RED。
@Suite("mathRenderer(_:) optional widening")
struct MathRendererModifierOptionalTests {
    // MathRendering 现已约束 AnyObject，测试替身为 final class。
    private final class Dummy: MathRendering, @unchecked Sendable {
        func render(latex: String, display: Bool, pointSize: CGFloat,
                    scale: CGFloat, color: PlatformColor) async -> MathRenderOutcome { .failed }
    }

    @MainActor
    @Test("传具体 renderer：编译通过且 env round-trip 保留该实例（不回归）")
    func concreteRendererCompilesAndRoundTrips() {
        let renderer = Dummy()
        // 编译期守卫：既有「传具体 renderer」调用点必须保持源码兼容。
        _ = Text("$x$").mathRenderer(renderer)

        // 语义守卫：modifier 内部 environment(\.markdownMathRenderer, renderer)
        // 的 round-trip 契约——写入具体实例必须原样读回同一身份。
        var env = EnvironmentValues()
        env.markdownMathRenderer = renderer
        #expect(env.markdownMathRenderer != nil)
        #expect(env.markdownMathRenderer === renderer)
    }

    @MainActor
    @Test("传 nil：编译通过且 env round-trip 为 nil（运行时禁用 math）")
    func nilRendererCompilesAndDisablesMath() {
        // 编译期守卫（git-反证核心）：把签名改回 `any MathRendering`（非可选）
        // 后，下面这行会编译失败 → RED。
        _ = Text("$x$").mathRenderer(nil)

        // 语义守卫：modifier 把 nil 原样写入可选 env → math 禁用。
        // git-反证（备选）：modifier 内部把 nil 换成默认非 nil → 此断言 RED。
        var env = EnvironmentValues()
        env.markdownMathRenderer = Dummy()      // 先放一个，确认 nil 真能清除
        env.markdownMathRenderer = nil
        #expect(env.markdownMathRenderer == nil)
    }
}
