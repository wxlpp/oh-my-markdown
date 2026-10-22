# iOS 正文链接命中修复

App 来源引用实际点击回归复现：第二段数字引用未触发 handler。触摸诊断显示点击坐标落在引用上，closestPosition 却给出全文末尾 offset 87（引用位置 68）。另有 UITextInteraction 内部手势与自有链接单击竞争。

- 按链接实际 selectionRects 字形范围命中，保持链接原始 URL/fragment；激活仍经 RenderSession policy、配置 revision 核对和 handler。
- 自有单击允许与同一文字视图的系统手势同时识别，不与父级滚动手势同时识别；不增加透明点击覆盖层。
- 新增跨段落单字符引用左/中/右命中及空白拒绝测试，加入 iOS runtime manifest。

## 验证

Xcode 26.4 / iOS 26.4 iPhone 17 Pro：`xcodebuild -scheme oh-my-markdown-Package -destination 'platform=iOS Simulator,id=02F33AA8-C904-4B64-BF66-3C14ADB94230' -only-testing:OhMyMarkdownTests/MarkdownLinkPolicyTests test`，17 项通过（含新用例）。实际运行复用了 App 的 DerivedData 与 SourcePackages 缓存；日志 /tmp/citations-library-tests.log。

`Scripts/check-link-activation.sh` 与 `git diff --check` 通过。App 真正手指点击回归已能打开来源并返回保持位置。没有宣称完成 iOS 18 发布矩阵、全量 suite 或超长链接文档性能验收。

## 独立评审

Claude Code，实际 modelUsage `claude-opus-5-5`，fastMode=false，定向静态评审结论 PASS。评审覆盖 6a1b3ef 的字形命中逻辑与测试；其后 ObjCBool 编译修正和同视图手势协调由本地构建、17 项测试及 App 真点击验证，不冒称另一次模型批准。

Minor：全篇链接矩形扫描只在点击时执行，超长链接密集文档性能、宽表格 overlay 尚未专项验收，保留为后续专项；不影响本次普通聊天引用目标。
