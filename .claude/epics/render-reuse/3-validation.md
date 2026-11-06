# 验证与评审记录

## 范围

修复聊天正文视图重建时异步解析造成的首帧空白；库提供可选、调用方持有的有界资源无关渲染模型缓存，App 按列表使用。全局 AI chat bar 不改。不自动合并。

## 实施进度

- 设计/计划提交 142863d 经独立 superpowers-reviewer 复审 PASS，补齐初始宽度交接、诊断计数隔离和 umbrella export。
- 先写平台失败测试：red-runtime.log 中3项期望失败（首次测量无正文、token、缓存命中）；随后实现后通过。
- 基础会话15项通过（baseline.log）。
- 当前主机9项定向测试通过（hosting.log，含参数化5项配置和2种SwiftUI消费方式）：平台首次同步恢复、后续异步append、过期source拒绝、资源跳过、容量清理、零frame表格连续proposal/实际bounds、旧recorder隔离、真正SwiftUI拆装首布局、umbrella consumer。
- SwiftUI拆装测试在重新构造之后到正文断言之间没有 await；不以异步最终完成冒充首帧。
- 完整 static gates 与 Claude Code只读评审运行中；后续追加真实结果。

## 证据边界

当前主机测试不等价 macOS15。用户明确要求暂缓该发布门槛；iOS18运行门槛也未覆盖。不声明库发布门槛通过。App 集成、原始帧验收、手机安装尚未完成。

## 决策

缓存仅在拆卸时写入，不在每次流式追加时复制或哈希全文；只收无异步资源模型，图片/数学/SVG仍走原有资源授权链。容量是原文UTF8预算，不伪称精确堆字节。缓存不保留UIView、选区或旧session诊断对象。

## 评审修复

- 完整当前主机测试：520 + 30项通过；平台floor、资源ownership、URL activation、format通过。严格Release失败在旧编辑器两个closure @Entry的新版编译器诊断，未绕过；改显式EnvironmentKey并局部禁止formatter改回宏，保持API/回调语义。
- iOS27.2：24项平台会话/首帧/SwiftUI测试通过（ios-first-frame.xcresult）。
- 独立checkpoint评审BLOCK：有效bounds后第二个proposal提前返回，保留了旧宽度bootstrap。新增失败复现width-red.log，修正拒绝路径清理；macOS先设置测量frame再恢复，匹配bounds的proposal同步交给driver。
- Claude Opus5.5/high标准模式评审REVISE：R1追加后缓存未命中不应清正文；R2 nil宽度探测不应发送巨宽replaceWidth。追加复现append-red.log后修复：只有宽度不匹配清临时正文，nil proposal不尝试缓存恢复。
- 深色+xxxLarge SwiftUI拆装以及首次高度断言已补；37项定向测试通过（review-green.log）。待严格Release复跑和评审修复复核。

## 当前通过结果（代码2e2cf69）

- static-reviewed：全部门槛通过；521项主测试 + 30项数学测试通过，严格Release `-warnings-as-errors`通过，format/平台floor/资源ownership/链接检查通过。
- ios-reviewed.xcresult：iOS27.2共25项测试通过（4 suites，包含新增width回归和4组hosting参数），不冒称iOS18。
- 独立checkpoint修复复核PASS；Claude Opus5.5/high复核PASS，完整报告 claude-fix.md。复用既有token、资源、LRU评审，不重复全审。
- Claude留有非阻断取舍：多宽度试探型容器可能重新排版/撤掉宽度失配bootstrap；App固定聊天列宽的目标路径仍须原始帧验证。当前缓存不是任意布局的无闪烁保证。
- 两处旧编辑器文件使用文件级swiftformat:disable environmentEntry，不是单行禁用；仅关闭该宏转换规则，其他格式规则仍运行。
- App已固定消费2e2cf69012aed243bb17481fab0696cf40733220，未合并。App真实回归/录屏进行中。
