---
name: copilot-cross-review
description: |
  当 CCPM 在 .claude/prds/ 或 .claude/epics/ 中生成或更新 PRD、epic 或
  任务拆解后，在该文档进入 CCPM 下一阶段之前，请先发起一次 Copilot CLI
  审查，作为第二意见。
---

# 使用 Copilot CLI 交叉审查

当 CCPM 的规格文档（PRD、epic、task）刚写完或发生较大改动，并且即将进入
下游阶段时，运行一次 Copilot CLI 审查，并整合其中有价值的结论。

## 步骤

1. 确认目标文件路径，例如 `.claude/prds/notification-system.md`。

2. 以程序化模式运行 Copilot CLI：

```bash
   copilot -p "请以资深产品/工程审查者的身份审查 @<file_path>。

   重点关注：
   - 完整性与内部一致性
   - 可衡量的验收标准
   - iOS 相关边界情况：离线、权限、前后台切换、
     空状态/错误状态、无障碍、本地化
   - 是否明确说明范围之外的内容
   - 是否存在隐藏假设

   忽略格式、错别字和 Markdown 风格。

   输出格式：
   🔴 Critical（阻塞继续推进）
   🟡 Should address（存在明显缺口）
   🟢 Suggestions（可选优化）
   ✅ Strengths（简要优点）" \
     --deny-tool='shell' \
     --allow-all-tools 2>&1
```

3. 将 Copilot 的结果分成四类：
  - 🔴 Critical：继续推进前必须修复
  - 🟡 Should address：结合我的判断展示给用户
    （同意 / 不同意 / 部分同意 / 需要更多上下文）
  - 🟢 Suggestions：简要记录，默认延后处理
  - ✅ Strengths：仅确认即可

4. 按以下顺序向用户给出一份行动计划：
  - 自动修复：结论明确、改法清晰的 🔴 或 🟡 项目
  - 询问用户：我与 Copilot 判断不一致，或存在取舍的问题
  - 延后处理：价值较低的 🟢 建议

5. 在用户确认后，再对规格文档实施修改。

6. 如果修改幅度较大，可选地再运行一次 Copilot CLI 做第二轮审查，
   但总轮数最多 2 轮，避免无限循环。

## 重要说明

- 不要盲目接受 Copilot 的反馈。它只是第二意见，不是最终权威；是否采纳由
  我的分析决定。
- 如果 Copilot 的结论有误，例如误解上下文或臆造需求，需要在汇总计划中明确
  说明原因。
- 审查轮数最多 2 轮，避免成本失控。
- 每次调用 Copilot CLI 都会消耗一次 Copilot premium 请求。