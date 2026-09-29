# 项目知识索引

本索引只描述当前有效知识。源码是实现事实，测试与实际操作是验证证据；产品方向不代表功能已经实现。

| 问题 | 阅读入口 | 需要同时检查 |
| --- | --- | --- |
| 复制粘贴测试 Markdown | [无图片样本](examples/markdown-paste-sample.md) | 复制文件原始文本，粘贴到正文；步骤见[验证](verification.md#markdown-粘贴样本) |
| 查看 Markdown 全集与实际效果 | [效果手册](examples/markdown-showcase.md) | Mac 复制正文粘贴、移动端可导入；已支持能力与兼容性对照分开标注 |
| 本期做什么、未来做什么 | [产品](product.md)、[本期规格](specs/first-release.md) | 用户本次范围 |
| 代码在哪里、数据如何保存 | [架构](architecture.md) | `Sources/Yours` |
| Mac 底板与双栏卡片、跨设备布局、正文样式和原生交互怎么设计 | [设计](../DESIGN.md) | 当前 App、[原生设计规则](../.agents/rules/apple-native-design.md) |
| App 品牌图标定稿、SVG 编辑与素材生成 | [图标设计](../DESIGN.md#app-品牌图标已确认设计) | [制作说明](../design/AppIcon/README.md)、[主 SVG](../design/AppIcon/yours-mark.svg) |
| Apple 原生 UI 规则、同心圆角、iOS / iPadOS / 折叠形态与视觉走查 | [设计规则](../.agents/rules/apple-native-design.md) | [设计基线](../DESIGN.md)、[验证](verification.md) |
| 按钮、链接和可点击区域的 pointer 规则 | [光标设计约定](../DESIGN.md#可点击区域的光标全局约定) | [指针验收](verification.md#可点击区域的指针验收) |
| 如何验证编辑器改动 | [验证](verification.md) | 受影响测试和目标平台 |
| Slash 搜索、选区格式与链接浮层 | [设计规则](../DESIGN.md#slash-与选区工具栏)、[命令边界](architecture.md#编辑命令与临时浮层) | [输入与选区验收](verification.md#slash-与选区格式回归) |
| 如何规划任务、记录证据、创建 PR | [开发流程](development.md) | `harness.yaml` 与安装版 Harness skill |

## 维护方式

行为变化更新本期规格；数据或模块边界变化更新架构；视觉与交互决策更新 DESIGN；新发现的回归场景更新验证清单。入口或命令变化同步修改关联链接和配置。

每项结论标明“现状”“方向”或“待验证”。当前知识不记流水账、历史失败日志或已放弃方案；任务推理和执行证据保留在任务记录 / Run 中。引用代码用文件和符号，避免容易漂移的行号。新增独立决策文档只用于有长期影响的取舍，不为小修复制造文档层级。

_Last updated: 2026-09-28 — 补充 Slash 与选区格式入口、共享事务和验证边界。Evidence: `EditorCommands.swift`, `NativeRichTextEditor.swift`, `EditorCommandContractTests.swift`, `NativeCommandTests.swift`._
