# 任务产品研究：共性、取舍与边界问题

研究日期：2026-10-21；2026-10-26 补充恢复位置专项核查。对象：Things 3、Todoist、滴答清单（TickTick）、Apple 提醒事项。

用途：为 Yours 的独立任务功能提供可追溯的参考，避免在内容、层级、日期、重复与恢复规则上遗漏关键场景。Yours 的已确认方向与未决项集中维护在[任务功能讨论稿](../specs/tasks.md)，本研究不自动授权实现任何功能。

## 阅读方法与证据边界

- 从四个官方帮助目录出发，按「记录 → 组织 → 安排 → 执行 → 完成/恢复 → 重复 → 同步」梳理核心章节，同时查看 FAQ 与更新日志中的真实问题。下方来源目录记录实际使用的页面与读取程度；不是全站逐篇通读。
- Apple 用户指南固定到 macOS 26，补充 EventKit 对重复提醒的官方解释；网页默认跳转到其他系统版本时不混用。其他产品为研究当天可访问的官方文档，具体客户端版本未实测。
- **文档事实**是厂商明确描述的行为；**跨产品共性**表示多个产品采用的共同思路，不表示所有细节一致；**研究建议/推导风险**是对 Yours 的设计判断，尚非确认需求。
- 部分 TickTick 页面直接打开无正文，改读同一官方页面的搜索索引内容；对应条目标为「索引」，不能据此声称完整读过正文。未取到的细节保留未知。
- Todoist 非正式环境域名的结果不作为定案依据。正式帮助页之间出现不一致时保留冲突，不自行挑选一个当作运行事实。订阅和平台限制只在影响行为解释时记录，不把付费限制当成设计原则。
- 本文基于文档，没有运行四款 App 的操作、视觉、通知送达或同步验收。没有找到说明，不等于产品不支持。

## 1. 四种产品思路

| 产品 | 文档体现的组织思路 | 对 Yours 的价值与边界 |
| --- | --- | --- |
| Things 3 | Area 承载长期责任，Project 承载较大的成果，任务中可写备注与 checklist；Today、Upcoming、Anytime、Someday 调整关注范围 | 借鉴「收集和执行分开」及时间语义；不直接照搬其层级或 Markdown 编辑方式。[T1][T2][T3] |
| Todoist | 项目、分区、任务/子任务与过滤视图组合，任务详情承载属性与上下文 | 借鉴完整子任务和视图组织；不能把项目树、任务树和显示分组混为一谈。[D1][D2][D3] |
| TickTick | Folder → List → Section → Task → Subtask；另有检查项、日历、专注、习惯等能力 | 借鉴不同使用深度和安排工具；不因此给 Yours 增加所有模块。[K1][K2] |
| Apple 提醒事项 | 清单、清单组、子任务与智能列表；按条件从原清单汇总任务 | 借鉴原生操作、来源归属和恢复路径；智能列表不是另一份任务数据。[A1][A2][A3] |

## 2. 跨产品共性与非共识

### 2.1 可以作为设计起点的共性

| 共性 | 依据 | Yours 设计时要回答的问题 |
| --- | --- | --- |
| 简短任务名与详细上下文分开 | Things notes、Todoist description、TickTick details、Apple reminder details。[T3][D4][K3][A4] | 仅标题能否快速创建？备注怎样搜索、保存与恢复？ |
| 大任务可以拆解，简单任务不必填满属性 | checklist、子任务或项目都用于降低拆解成本，但能力不同。[T1][D2][K2][A2] | 子任务可只写标题，还是必须打开详情？ |
| 组织归属和执行视图分开 | 项目/清单用于组织；Today、Upcoming、Smart Lists 用于聚合。[T2][D5][A3] | 同一个任务出现在多处时是否仍是同一身份？ |
| 收集可以早于安排 | Things Inbox、Todoist Inbox 允许先收集后整理。[T1][D6] | Inbox 是未归类任务还是全量任务视图？不能因名称相同沿用文档 Inbox 的语义。 |
| 日期、通知与完成是不同动作 | Things 明确区分开始日期、提醒和 deadline；其他产品也有日期与提醒设置。[T2][D7][K4][A4] | 日期到来/通知触发不能暗中完成任务。 |
| 重复需要明确何时推进及如何结束 | 四款产品均有重复机制，触发与状态模型存在差异。[T4][D8][K5][A5] | 当前周期、下一次、跳过、停止系列如何区分？ |
| 完成记录和删除/恢复需要各自的路径 | Apple 有完成状态和最近删除；Todoist 单列完成记录与备份说明。[A6][A7][D9][D10] | 已完成如何找回？删除如何恢复？不能让二者共用一种隐藏状态。 |

以上是方向上的共性，不是逐字段一致的行业标准。

### 2.2 不能直接当成共识的选择

| 问题 | 已观察到的差异 | 对 Yours 的含义 |
| --- | --- | --- |
| 检查项是否等于子任务 | TickTick 明确保留两种；Todoist 将子任务作为可安排的任务；Things 使用备注与 checklist。[K2][D2][T3] | 不应仅为竞品对齐，强迫用户理解两种相似对象。 |
| 开始日期是否隐藏未来任务 | Things 用未来开始日期让任务暂离当前执行视图；Todoist 的 duration 文档说明不提供按开始时间隐藏任务的机制。[T2][D11] | 「何时显示」「何时执行」「何时截止」必须分别定义。 |
| 固定周期是否累积 | Things 固定周期按日历产生副本；Apple 只提供当前未完成提醒；Todoist 完成后推进日期。[T4][A5][D8] | 日期锚点与累积策略是独立决策。Yours 已选不累积。 |
| 完成父任务是否级联 | Apple 明确完成、删除或移动父任务会相应处理子任务；Todoist 另有重复任务子项重置设置。[A2][D12] | 「子全完成不自动完成父」不能代替「勾父时怎么处理子」的规则。 |
| 富文本支持程度 | Things 备注保留 Markdown 标记；TickTick 的更新日志描述隐藏格式标记等编辑改进。[T3][K9] | Yours 已选富文本，应复用自身编辑边界，不迁就竞品文本存储。 |
| 历史是否是可恢复的任务 | Todoist 对重复任务说明为日期推进及完成日志，历史条目不等于可直接取消完成的独立副本。[D9] | 不累积并不决定历史存储结构，也不保证能够撤销任意历史周期。 |
| 同步是否要求独立账户 | Things 使用 Things Cloud，Apple 指南区分 iCloud 与其他账户的功能。[T5][A1] | Yours 沿用自己的本地优先与可选 CloudKit，不照搬账户体系。 |

## 3. 按能力归纳可学习的设计

### 3.1 任务内容与拆解

**文档事实。** TickTick 在引入任务嵌套时，将原有描述内的子项改称 Check Item；新的子任务拥有更多完整任务属性。[K2] Todoist 鼓励为子任务单独安排日期与提醒。[D2] Things 的备注可格式化、搜索，但标题保持简洁呈现。[T3]

**研究建议。** Yours 的结构化子任务可以轻到只有标题和勾选框，时间、备注按需补充；不把「尚未安排」定义成另一种任务类型。富文本内的勾选段落是否与结构化子任务混排或关联仍需单独确认。文档内 Todo 聚合已移出当前范围，不能从此研究推导为首版自动汇总。

需要提前规定：标题空值和多行粘贴、备注保存与搜索、子任务排序、移出父任务、跨项目移动、父子循环引用、删除父任务、完成后新增子任务。它们是推导风险，并非宣称竞品都有这些缺陷。

### 3.2 项目归属、文件夹与视图

**文档事实。** Things Area 表达持续责任，Project 表达较大成果。[T1] Todoist 个人项目可有子项目，团队项目使用文件夹组织，层级能力有适用范围。[D1] Apple 智能列表筛选后，任务仍属于原清单；普通清单转为智能清单则可能改变归属与父子关系。[A3]

**研究建议。** Yours 先确定「多级文件夹」「项目清单」「任务」各自是否能包含内容、是否可完成/归档，再画侧栏。标签与层级分别解决多维筛选和单一归属，第一版省略标签是范围取舍，不是两者等价。

Today、即将到来、搜索都应是同一任务集合上的视图。新增于某个筛选视图时，需要解释归属和默认日期；移出当前筛选后消失应有可理解反馈。任务有多段安排时，任务列表去重与日历时段展示需分别定义。

### 3.3 日期、时长、多个时段与 DDL

**文档事实。** Things 与 Todoist 都说明计划处理日期和硬截止的差别。[T2][D7] Todoist 的 duration 章节描述时长及其限制；TickTick 提供开始/结束时间与不同提醒时机。[D11][K3][K4] Todoist、TickTick 均区分固定时区与浮动本地时间。[D13][K6]

**研究建议。** Yours 先把术语固定下来，避免全部叫「时间」：

| 术语 | 回答的问题 | 不能混同 |
| --- | --- | --- |
| 计划日期 | 哪一天准备处理？ | 不等于必须完成日 |
| 执行时段 | 哪一段时间用于这项任务？可有多段 | 不等于新的任务或重复次数 |
| 预计投入 | 大概需要多少工作量？ | 不等于已排入日历的时长；是否首版提供待确认 |
| 截止日期/时间 | 最晚什么时候完成？ | 不等于重复结束日 |
| 提醒 | 哪个时刻通知用户？ | 不等于安排，也不能保证系统一定送达 |
| 实际投入 | 真实工作了多久？ | 不能用计划时段自动充当；计时不在当前确认范围 |

Yours 的多个不连续执行时段是明确需求。本轮文档不足以证明四款产品都原生支持同一任务多时段，也不足以断言都不支持。不要把跨日长条、重复任务、多个子任务当作该需求的等价实现。

父任务可整体安排，子任务仅作步骤；也可分别安排子任务，父任务只设 DDL。汇总需区分工作量求和、时间区间覆盖和忙碌时间去重；父子同时安排同一小时不能不加解释地算成两小时。具体汇总规则仍待定。

### 3.4 重复：本次、规则和历史

| 产品 | 官方描述的关键行为 | 证据限制 |
| --- | --- | --- |
| Things | 完成后间隔随完成时间变化；固定日历即使前次未完成仍生成新副本。支持调整单次或更新重复规则。[T4][T6] | 不能把其副本模型强加给不累积设计 |
| Todoist | 完成后推进日期；每日逾期完成推进到未来；子任务重置可配置；撤销完成会回退日期，历史恢复有额外限制。[D8][D9][D12] | 两篇正式文档对手动改期后基准的描述存在差异，见下节 |
| TickTick | 支持按完成日期重复、单次改期、结束日/次数以及未来周期展示；FAQ 说明当前未处理前不能修改未来周期。[K1][K5][K7] | 部分内容仅取得官方索引；结束条件细节不能直接照搬 |
| Apple | EventKit 与提醒事项只提供重复集合第一个未完成项；完成后下一次才可用。[A5] | 该说明不能证明漏期跳过、历史模型、改期基准等所有细节 |

**Yours 已确认：不累积，支持固定周期与完成后间隔。** 这只确定两个维度，还没有确认完整状态机。至少要把「完成本次」「跳过本次」「停止重复」「删除本次/系列」「撤销完成」分开讨论。

日历的未来周期可由规则推演，不必预先创建大量待办。若后续提供预览，须区分可执行当前项和推演项；完成后间隔的未来时间在本次完成前只能估计，不应呈现为确定承诺。

### 3.5 执行、排序与原生交互

**文档事实。** Todoist 分组/自动排序会限制手动拖排，子任务顺序另在父任务详情中处理。[D3] Apple 某些智能列表中不能直接通过缩进创建子任务。[A2] Things 为创建、导航和格式操作提供键盘入口。[T7]

**研究建议。** 显示顺序与手动顺序应分开保存；切换排序不应破坏原来的人工安排。拖到另一日期究竟修改单个时段、全部时段还是任务计划日期，需要在 Yours 多时段模型下重新定义。触控、键盘、中文输入法、VoiceOver 和撤销仍按项目[原生设计规则](../../.agents/rules/apple-native-design.md)验收，不能凭说明文档认定竞品手感或性能更好。

### 3.6 完成、删除、同步与通知

**文档事实。** Apple 最近删除允许在规定期限恢复；删除整个清单也会影响其中提醒。[A7] Todoist 把完成记录、备份和离线使用分别说明。[D9][D10][D14] TickTick FAQ 提醒检查系统通知权限。[K1] 这些材料说明恢复入口、保存状态和系统权限需要显式设计，但没有证明任何产品在所有异常场景都安全。

**研究建议。** Yours 的本地保存失败、同步失败、通知权限关闭必须分别呈现。不能让任务开关被云端旧状态覆盖，不能因清空本地缓存丢失离线工作；取消或完成后应撤销旧通知。两台设备同时完成同一重复任务时，需要保证只推进一次，不能生成两个下期任务。

Yours 当前文档同步仍有整库快照、前台轮询和未实现删除传播等限制，见[存储与同步](../storage-and-sync.md)。「任务同步对齐文档」是产品方向，不表示现有代码已自动支持任务删除、重复推进和通知的一致性。

### 3.7 恢复时原父任务或项目不存在（2026-10-26 补充）

| 产品 | 本次官方材料能确认的行为 | 原位置不存在时仍不能确认的部分 |
| --- | --- | --- |
| Apple 提醒事项 | iPhone 指南明确「恢复」后任务进入默认清单；Mac 可从最近删除拖到指定的普通清单，不接受智能列表作为目标。[A9][A10] | 不据此断言自动恢复完整父子链，也不能把默认清单等同于固定的 Inbox |
| Things 3 | FAQ 说明 Mac 的任务/项目可从 Trash 恢复，也可撤销删除；iOS 没有同样的回收站入口。[T8] | FAQ 未明确原项目已删除时的默认目的地，需要当前客户端验证 |
| 滴答清单 | 中文官方 FAQ 说明删除任务可从垃圾桶找回，多级任务文档也说明子任务可以恢复。[K10][K11] | 本次未找到原清单/父任务不存在时恢复到哪里的官方规则，不推测其一定进入收集箱 |
| Todoist | 官方备份恢复流程是：提取删除前的项目 CSV，创建新项目后导入；不等于原身份和原位置的一键还原。[D10] | 不能从这个备份流程推导一般回收站的自动归位规则；恢复完成任务的 API 也不是恢复已删除任务 |

**产品取舍。** 恢复到原位置、进入默认收集位置、让用户指定目的地，是需要分别选择的产品策略，没有查到四款产品都遵循「父不存在 → 原项目顶层 → Inbox」的共识。Yours 已在 2026-10-26 确认采用这条降级路径，见[功能讨论稿 C23](../specs/tasks.md)；依据是用户选择，不是竞品共识。

### 本次补充来源

- **A9** [Delete or recover items on iPhone](https://support.apple.com/guide/iphone/delete-and-recover-reminders-iph51b488c05/ios)（正文/官方索引）：恢复到默认清单。
- **A10** [Delete reminders on Mac](https://support.apple.com/en-in/guide/reminders/remna83c9566/mac)（正文/官方索引）：拖到另一普通清单恢复；此处是当次网页说明，不替代上文 macOS 26 固定版本来源。
- **T8** [Things FAQ：Restoring deleted to-dos](https://culturedcode.com/things/support/articles/2967034/)（官方索引正文）：Mac/iOS 回收站差异，未说明缺失原位置的归位规则。
- **K10** [滴答清单常见问题](https://help.dida365.com/articles/6950670128287580160)（官方索引）：垃圾桶找回任务。
- **K11** [滴答清单多级任务](https://help.dida365.com/articles/6950660746367729664)（官方索引）：子任务可从垃圾桶恢复。
- D10 原链接现跳转到[备份恢复正式页面](https://www.todoist.com/help/account-and-billing/security/download-or-restore-backups-in-todoist-ywaJeQbN)，本次读取 Restore a backup 章节，确认新建项目后导入的流程。

## 4. 官方材料已经暴露的问题

| 编号 | 官方事实或文档冲突 | 对 Yours 的检查点 |
| --- | --- | --- |
| E1 | Todoist 子任务重置文档提示嵌套深度、数量和顺序限制。[D12] | 下期重置是否完整，是否保留顺序，不能只测一级两项 |
| E2 | Todoist 完成重复任务后，短时撤销与历史条目的取消完成不是同一种能力。[D8][D9] | 撤销要同时处理日期、子任务、本次历史和下一次状态 |
| E3 | Todoist 的「完成重复任务」页泛述手动改期后按完成日计算；「重复日期介绍」页又按绝对/相对规则区分。[D8][D15] | 未实测前保留冲突；Yours 明确定义「仅改本次」不修改固定周期锚点，而不是复制模糊说法。此行为目前仍为建议 |
| E4 | Todoist 正式 duration 页与非正式环境索引对「无日期能否设时长」不一致 | 以正式页作为本轮证据；不给 Yours 的预计时长添加没有自身理由的限制；该产品现状需客户端复核 |
| E5 | Todoist 2026-09-17 更新记录修复撤销重复父任务时子任务状态错误，以及同步重置涉及未同步内容的问题。[D16] | 回退应恢复精确旧状态，不能把全部子任务统一设成同一值 |
| E6 | 同一日志 2026-09-24 描述离线创建任务所属项目被删除后的同步兜底；2026-03-12 描述跨午夜/夏令时的日历问题。[D16] | 删除与离线编辑冲突不能丢失任务或无限重试；日历日期不能用固定秒数代替本地日历运算 |
| E7 | Apple 普通清单转智能清单会移动任务，并可能解除父子关系。[A3] | Yours 的视图切换不应悄悄改写层级，若有实体转换须明确后果 |
| E8 | TickTick FAQ 将未来重复周期不可编辑与未处理当前周期关联。[K1] | 未来预览需展示操作能力边界；不能显示能点但无法解释原因的控件 |

这些是文档记录的行为、限制或已修复问题，不表示当前版本仍有对应缺陷。

## 5. Yours 待讨论与后续验收场景

以下是由研究推导的场景库；不是已实现规格，也没有执行 App 验收。「已定」只指产品决定，其余预期须在编码前确定。

| 场景 | 要锁定的规则/检查点 |
| --- | --- |
| 只输入标题创建任务，不设日期与项目 | 默认归属、空标题处理、保存触发 |
| 备注写 checklist，另建无日期子任务 | 两者的能力、是否混排、是否计入进度 |
| 全部子任务完成 | 已定：父任务保持未完成，等待用户勾选 |
| 勾父任务时仍有未完成子任务 | 级联完成、保留或确认；恢复父任务是否恢复孩子 |
| 子任务移动到其他项目/父任务、移动到自己的后代 | 跟随关系、解除关系、防环及撤销 |
| 清单/文件夹删除后恢复 | 子树、手动顺序、重复规则和通知是否一起恢复 |
| 一个任务安排今天上午和后天晚上 | 已定支持多段；列表任务计数、日历分段和取消单段规则 |
| 父安排 10–12 点，子安排 10–11 点 | 汇总不能未经定义重复计数；区分整体时间与额外工作 |
| 计划日过去但 DDL 未到 | 待处理与逾期分别按什么字段判断 |
| 执行时段或子任务安排超出父 DDL | 提示还是阻止，是否传播修改 |
| 每周六任务拖到周日完成 | 固定周期保持日历锚点；具体推进边界待确认 |
| 完成后七天重复，周日完成 | 下一次按完成时刻/本地日期如何计算 |
| 固定每日任务十天未完成 | 已定不累积、不重置当前进度；漏期跳过和历史如何记仍待定 |
| 今天连续勾两次/双击完成 | 提前完成下期是否允许，避免误触推进两次 |
| 跳过本次、停止重复、删除系列 | 分别对历史、子任务与通知有什么影响；是否首版支持待定 |
| 本期临时加了一个子任务或改了备注 | 只影响本次还是自动更新下期模板 |
| 子任务有多段安排，父任务重复 | 子时段采用周期相对偏移、固定星期或绝对日期；尚未定案 |
| 撤销父任务完成，下期已经被修改或被另一设备推进 | 恢复范围、冲突提示，不覆盖新输入 |
| 每月 31 日、2 月 29 日、工作日、结束次数 | 缺失日期策略，次数按完成/发生/跳过计数 |
| 跨午夜、旅行换时区、夏令时切换 | 全天日期不能漂移；浮动时间/固定时区与日历间隔分别计算 |
| 两设备离线完成同一个重复任务 | 推进去重，完成时间与新周期状态一致 |
| 一设备删除父任务，另一设备编辑子任务 | 删除冲突与可恢复性，不能用整库覆盖吞掉工作 |
| 关闭通知权限、改期、完成、删除、重启 | 状态可解释；旧通知取消，新通知不重复注册 |
| 从 Today 搜索结果改日期/完成后行消失 | 反馈、焦点与撤销后位置；编辑中不被刷新抢走输入 |
| 大量任务、深层目录、长备注、中文/emoji 搜索 | 查询范围、展开状态、稳定身份及分页/性能；不预设规模上限 |

优先讨论：父子完成联动 → 重复的漏期/跳过/改期/子项重置 → 多时段与 DDL → 项目组织 → 页面与输入流程。数据身份、删除冲突和推进去重应在技术设计阶段落实，不能等 UI 完成才补。

## 6. 来源目录与覆盖范围

来源代号只用于本文追溯。所有链接为官方来源；「正文」表示读取与结论相关的正文段落，不表示复制或通读全站；「索引」表示只取得官方页面在搜索中的内容。核查日期均为 2026-10-21。

### Things 3

- 入口：[Things Support](https://culturedcode.com/things/support/)（目录）。
- **T1** [Getting Productive with Things](https://culturedcode.com/things/support/articles/6378414/)（正文）：收集、项目、Area 与日常安排。
- **T2** [Scheduling To-Dos](https://culturedcode.com/things/support/articles/2803579/)（正文）：默认视图、开始日期、提醒与 DDL。
- **T3** [Writing Notes](https://culturedcode.com/things/support/articles/4438545/)（正文）：格式、checklist、搜索与平台限制。
- **T4** [Choosing a Repeat Pattern](https://culturedcode.com/things/support/articles/3743733/)（正文）：固定周期与完成后间隔、累积差异。
- **T5** [Syncing with Things Cloud](https://culturedcode.com/things/support/articles/2803586/)（正文）：同步服务与本地单设备使用边界。
- **T6** [Repeating To-Dos, Refined](https://culturedcode.com/things/blog/)（官方博客相关文章）：提前完成、本次例外与更新规则；博客首页会变化，按文章标题定位，后续引用需复核。
- **T7** [Keyboard Shortcuts for Mac](https://culturedcode.com/things/support/articles/2785159/)（正文）：键盘操作入口。
- 补充：[Using Tags](https://culturedcode.com/things/support/articles/2803581/)、[Connecting Your Calendars](https://culturedcode.com/things/support/articles/2803583/)（浏览）；本文没有据此推断任意多级分类或双向日历同步。

### Todoist

- 入口：[Help Center](https://www.todoist.com/help)、[Features](https://www.todoist.com/help/todoist/features)（目录）。
- **D1** [Introduction to projects](https://www.todoist.com/help/todoist/features/introduction-to-projects-TLTjNftLM)（正文）：项目与分区、个人/团队层级差异。
- **D2** [Use sub-tasks](https://www.todoist.com/help/todoist/features/use-sub-tasks-in-todoist-kMamDo)（正文）：独立安排与顺序限制。
- **D3** [Sort or group tasks](https://www.todoist.com/help/todoist/features/sort-or-group-tasks-in-todoist-WFWD0hrb)（正文）：手动排序、分组及子任务顺序。
- **D4** [Add a task description](https://www.todoist.com/help/todoist/features/add-a-task-description-in-todoist-rOryWIHn)（正文）：详情、创建和搜索。
- **D5** [Plan your day with Today](https://www.todoist.com/help/todoist/get-started/plan-your-day-with-the-today-view-UVUXaiSs)（正文）：跨项目汇总及日期筛选。
- **D6** [Use the Inbox](https://www.todoist.com/help/todoist/get-started/use-the-inbox-in-todoist-HwHvYErS)（正文）：未归类任务的收集与整理。
- **D7** [Introduction to deadlines](https://www.todoist.com/help/todoist/features/introduction-to-deadlines-in-todoist-uMqbSLM6U)（正文）：计划日和固定截止的区别。
- **D8** [Complete a task with a recurring date](https://www.todoist.com/help/articles/complete-a-task-with-a-recurring-date-dmI6SVqdP)（正文）：推进、逾期、停止与撤销。
- **D9** [View completed tasks](https://www.todoist.com/help/todoist/features/view-completed-tasks-in-todoist-J19h2s)（正文）：重复任务日志与历史恢复限制，含实验性/平台差异。
- **D10** [Download or restore backups](https://www.todoist.com/help/articles/115001799989)（正文/索引）：备份与恢复入口，不作为完整导出格式结论。
- **D11** [Set a task duration](https://www.todoist.com/help/todoist/features/set-a-task-duration-L1kYkZv8d)（正文）：安排与时长限制；与非正式环境索引存在差异。
- **D12** [Reset a sub-task](https://www.todoist.com/help/todoist/features/reset-a-sub-task-in-todoist-V6SRBGPw0)（正文）：重置选项、嵌套/数量/顺序限制。
- **D13** [Set a fixed time or floating time](https://www.todoist.com/help/todoist/features/set-a-fixed-time-or-floating-time-for-a-task-YUYVp27q)（正文）：时区语义。
- **D14** [Use Todoist while offline](https://www.todoist.com/help/todoist/features/use-todoist-while-offline-4rbaZw)（正文/索引）：离线操作和未同步内容的注意事项；不泛化为所有客户端退出必然丢数据。
- **D15** [Introduction to recurring dates](https://www.todoist.com/help/todoist/features/introduction-to-recurring-dates-YUYVJJAV)（正文）：重复规则、未来预览与改期。
- **D16** [2026 Changelog](https://www.todoist.com/help/todoist/product-updates/2026-changelog-HD3jJAtLd)（相关日期条目）：重复撤销、离线同步、跨午夜/夏令时问题。不是当前缺陷清单。

### TickTick / 滴答清单

- 入口：[Help Center](https://help.ticktick.com/)（目录）；研究使用英文 TickTick 帮助，不假定中国版各客户端完全一致。
- **K1** [FAQ](https://help.ticktick.com/articles/7055792921664028672)（官方索引含多个完整问答）：层级、未来重复、跳过、通知与备份。
- **K2** [Task Nesting 与 Check Item](https://blog.ticktick.com/2020/08/10/how-task-nesting-helps-you-with-gtd/)（官方历史文章正文）：两种概念的设计来由，不当作当前版本的全部限制。
- **K3** [Task Details](https://help.ticktick.com/articles/7055782408586526720)（索引）：详情、检查项、开始/结束安排；编辑效果未实测。
- **K4** [Effective Reminder Feature](https://help.ticktick.com/articles/7055782395743567872)（索引）：提醒触发与权限相关能力，平台限制须接入前复核。
- **K5** [Set Up Recurring Tasks](https://help.ticktick.com/articles/7055782206349770752)（索引）：完成后重复、结束条件、单次改期与预览；文中结束日/次数例子的解释不足，不据此定义 Yours 行为。
- **K6** [Time Zone](https://help.ticktick.com/articles/7082251620645339136)（正文/索引）：固定时区与浮动时间。
- **K7** [Calendar View Options](https://help.ticktick.com/articles/7055782085826445312)（正文/索引）：显示全部重复周期与检查项等显示选项。
- **K8** [Kanban View](https://help.ticktick.com/articles/7055782353376903168)（正文/索引）：列表的不同显示方式、分组与手动整理边界。
- **K9** [Web Changelog](https://ticktick.com/public/changelog/en.html)（相关条目）：编辑器和分组改进，仅作为 Web 版本事实。

### Apple 提醒事项

- **A1** [macOS 26 用户指南](https://support.apple.com/guide/reminders/welcome/7.0/mac/26)（目录与相关说明）：账户与功能可用性。
- **A2** [Add and remove subtasks](https://support.apple.com/en-my/guide/reminders/remn32a9622b/7.0/mac/26)（正文）：创建、智能视图限制、父任务级联操作。
- **A3** [Create custom Smart Lists](https://support.apple.com/en-my/guide/reminders/remnfec66479/7.0/mac/26)（正文）：任务仍留原清单，实体转换的副作用。
- **A4** [Add dates or locations](https://support.apple.com/guide/reminders/add-dates-or-locations-to-reminders/remnd4b206fb/7.0/mac/26)（正文）：日期、重复与提醒相关配置。
- **A5** [Creating a recurring event](https://developer.apple.com/documentation/eventkit/creating-a-recurring-event)（官方索引中的 Overview；页面正文需 JavaScript，Markdown 入口本次读取失败）：EventKit 及提醒事项仅提供第一个未完成重复提醒。
- **A6** [Mark reminders completed or incomplete](https://support.apple.com/guide/reminders/mark-reminders-complete-or-incomplete-remndbeda47c/7.0/mac/26)（正文）：完成状态与查看入口。
- **A7** [Delete reminders](https://support.apple.com/en-my/guide/reminders/remna83c9566/7.0/mac/26)（正文）：最近删除、恢复与清单级删除。
- **A8** [Organise reminder lists](https://support.apple.com/en-my/guide/reminders/remnee767c58/7.0/mac/26)（正文）：清单组与分组查看；不是任意层级文件夹能力的证明。

## 7. 如何继续使用这份研究

1. 讨论某项能力时，先查对应章节和场景；把选择写入[功能讨论稿](../specs/tasks.md)，不要从参考产品行为直接推导为 Yours 规格。
2. 关键行为在准备采用前，复核官方文档，并在必要时用当前客户端走一遍。尤其是标记为索引、历史文章、平台差异和冲突的来源。
3. 功能规则稳定后再做页面与交互设计；技术方案必须回答身份、历史、原子操作、同步与通知，不提前承诺数据结构。
4. 实现后将被采用的场景补入测试与[验证清单](../verification.md)。研究场景不能写成已通过证据。

[T1]: https://culturedcode.com/things/support/articles/6378414/
[T2]: https://culturedcode.com/things/support/articles/2803579/
[T3]: https://culturedcode.com/things/support/articles/4438545/
[T4]: https://culturedcode.com/things/support/articles/3743733/
[T5]: https://culturedcode.com/things/support/articles/2803586/
[T6]: https://culturedcode.com/things/blog/
[T7]: https://culturedcode.com/things/support/articles/2785159/
[D1]: https://www.todoist.com/help/todoist/features/introduction-to-projects-TLTjNftLM
[D2]: https://www.todoist.com/help/todoist/features/use-sub-tasks-in-todoist-kMamDo
[D3]: https://www.todoist.com/help/todoist/features/sort-or-group-tasks-in-todoist-WFWD0hrb
[D4]: https://www.todoist.com/help/todoist/features/add-a-task-description-in-todoist-rOryWIHn
[D5]: https://www.todoist.com/help/todoist/get-started/plan-your-day-with-the-today-view-UVUXaiSs
[D6]: https://www.todoist.com/help/todoist/get-started/use-the-inbox-in-todoist-HwHvYErS
[D7]: https://www.todoist.com/help/todoist/features/introduction-to-deadlines-in-todoist-uMqbSLM6U
[D8]: https://www.todoist.com/help/articles/complete-a-task-with-a-recurring-date-dmI6SVqdP
[D9]: https://www.todoist.com/help/todoist/features/view-completed-tasks-in-todoist-J19h2s
[D10]: https://www.todoist.com/help/articles/115001799989
[D11]: https://www.todoist.com/help/todoist/features/set-a-task-duration-L1kYkZv8d
[D12]: https://www.todoist.com/help/todoist/features/reset-a-sub-task-in-todoist-V6SRBGPw0
[D13]: https://www.todoist.com/help/todoist/features/set-a-fixed-time-or-floating-time-for-a-task-YUYVp27q
[D14]: https://www.todoist.com/help/todoist/features/use-todoist-while-offline-4rbaZw
[D15]: https://www.todoist.com/help/todoist/features/introduction-to-recurring-dates-YUYVJJAV
[D16]: https://www.todoist.com/help/todoist/product-updates/2026-changelog-HD3jJAtLd
[K1]: https://help.ticktick.com/articles/7055792921664028672
[K2]: https://blog.ticktick.com/2020/08/10/how-task-nesting-helps-you-with-gtd/
[K3]: https://help.ticktick.com/articles/7055782408586526720
[K4]: https://help.ticktick.com/articles/7055782395743567872
[K5]: https://help.ticktick.com/articles/7055782206349770752
[K6]: https://help.ticktick.com/articles/7082251620645339136
[K7]: https://help.ticktick.com/articles/7055782085826445312
[K8]: https://help.ticktick.com/articles/7055782353376903168
[K9]: https://ticktick.com/public/changelog/en.html
[A1]: https://support.apple.com/guide/reminders/welcome/7.0/mac/26
[A2]: https://support.apple.com/en-my/guide/reminders/remn32a9622b/7.0/mac/26
[A3]: https://support.apple.com/en-my/guide/reminders/remnfec66479/7.0/mac/26
[A4]: https://support.apple.com/guide/reminders/add-dates-or-locations-to-reminders/remnd4b206fb/7.0/mac/26
[A5]: https://developer.apple.com/documentation/eventkit/creating-a-recurring-event
[A6]: https://support.apple.com/guide/reminders/mark-reminders-complete-or-incomplete-remndbeda47c/7.0/mac/26
[A7]: https://support.apple.com/en-my/guide/reminders/remna83c9566/7.0/mac/26
[A8]: https://support.apple.com/en-my/guide/reminders/remnee767c58/7.0/mac/26
[A9]: https://support.apple.com/guide/iphone/delete-and-recover-reminders-iph51b488c05/ios
[A10]: https://support.apple.com/en-in/guide/reminders/remna83c9566/mac
[T8]: https://culturedcode.com/things/support/articles/2967034/
[K10]: https://help.dida365.com/articles/6950670128287580160
[K11]: https://help.dida365.com/articles/6950660746367729664

## 2026-10-27：任务页视觉与桌面布局专项

本轮起因：用户明确否定现有任务页观感。此前规范修复与操作验收只证明部分一致性/可操作性，不能作为页面设计质量已被用户接受的依据。当前截图的问题包括内容横向铺满、每行长分隔线重复、导航藏于菜单、重复添加入口、辅助信息机械换行、缺少项目和任务层级。

### 观察边界

查看厂商官方公开截图及说明，不等于已安装四款客户端或实测其当前交互。Things 官网跨设备截图与当前产品视频海报分别观察；TickTick features 的简化示意不能代替桌面界面，因此改以 Mac 产品页截图为布局依据；Todoist 官网部分图片为手机展示，桌面详情改以帮助页 Task view 截图为依据；Apple 固定 macOS 26 用户指南。

| 来源 | 实际观察 | 可借鉴的设计判断 |
| --- | --- | --- |
| [Things 官网](https://culturedcode.com/things/)、[功能页](https://culturedcode.com/things/features/) | 桌面侧栏并列系统视图与项目；项目任务以标题分组，行较紧凑，组内不逐条使用长粗分隔线 | 用常驻导航和受约束的内容宽度建立秩序；普通任务只保留必要信息，组间留白比行间边框更重要 |
| [Todoist Task view](https://www.todoist.com/help/articles/use-the-task-view-to-manage-tasks-in-todoist-eDeRDO0C) | 主体包含标题、描述、子任务；右侧承载项目/日期等属性 | 任务内容和安排属性有主次，不宜为了复用表单把所有属性平铺在标题下 |
| [TickTick Mac](https://ticktick.com/mac) | 官方图展示清单侧栏、中间任务列表、右侧当前任务；选中行柔和强调，分组标题明确 | 富文本备注/多时段较重时可用可收起详情栏，保留列表上下文；不需要复制番茄钟、习惯等其他功能 |
| [提醒事项：macOS 26 列表与列](https://support.apple.com/guide/reminders/remn1d887139/7.0/mac/26) | 清单名突出，普通任务较轻，分组作为主要结构 | 页面身份应由稳定标题表达；不是每条任务都需要完整边框或大行高 |

这些“可借鉴”是 Yours 的设计推导，不是厂商公布的通用尺寸标准。没有把截图测量值、付费功能、标签/优先级或协作能力自动变成 Yours 需求。

### 比较过的视觉方向

1. 聚焦当天：常驻视图/项目侧栏，正文限宽，紧凑列表；选中任务就地展开，适合轻量日清单。
2. 列表与详情并行：侧栏 + 中间列表 + 可收起右侧详情；适合频繁编辑富文本、子任务和多段执行安排。
3. 项目大纲：侧栏 + 按项目分组的任务树；父子关系直接可见，用缩进、折叠和分组留白表达结构，避免重复平铺父与子。

三方向沿用 Yours 现有功能栏、系统字体、SF Symbols、蓝色强调、文本画布与本地任务语义；比较布局与交互结构，不随机更换品牌风格。用户最终选定项目大纲与可选详情，当前实现基线见 DESIGN.md。

### 用户收敛：项目大纲 + 可选右侧详情

用户选择以第三张项目大纲为基础，并结合第二张右侧详情栏。列表展开只显示子任务，不内联展开备注编辑卡片；行前箭头负责子任务折叠，点击任务标题打开右侧详情，完成框独立切换状态。关闭详情后让列表恢复可用空间，项目分组和父子展开状态保留。合并概念已用于本轮实现；项目配色、示例分组与图内文案不自动扩展现有任务模型。


### 2026-10-27：时间入口收敛

用户确认统一「时间安排」：默认仅日期，按需设置提醒和开始/结束日期时间，再按需添加多段；截止日期单独保留。提醒是可选通知，执行时段是预留时间，两者分别维护，不由时段推导必须通知。默认只选择日期，不自动扩展成整天占用。

参考依据：[Apple 日期后按需添加时间](https://support.apple.com/en-ca/guide/reminders/remndc729e28/mac)、[Things 开始日期与独立截止](https://culturedcode.com/things/support/articles/2803579/)、[TickTick 日期与时段](https://help.ticktick.com/articles/7055782408586526720)、[Todoist 日期/时间后添加时长](https://www.todoist.com/help/todoist/features/set-a-task-duration-L1kYkZv8d)。多段是 Yours 在此基础上的产品扩展，不宣称四款竞品都有同样能力。

项目大纲与可选右侧详情、集中时间区已进入 SwiftUI 实现；生成图仍只是设计参考，实际验证记录另见验证文档与本地执行证据。
