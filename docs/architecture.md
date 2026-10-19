# 当前架构

## 工程与输入

现状：SwiftUI 组织界面，macOS / iOS 26 为基线；Swift Package 使用 Swift 6.2。共享 App target 位于 `Yours.xcodeproj`，Package 用于带覆盖率的单测；`UITests/YoursUITests.swift` 通过 Xcode UI test target 在 Mac 和 iPhone 模拟器运行。

| 文件 | 职责 |
| --- | --- |
| `Sources/Yours/App/ToastPresenter.swift` | 页面级短暂反馈消息、替换与关闭状态 |
| `Sources/Yours/App/Toast.swift` | Liquid Glass 反馈浮层；生命周期由 SwiftUI task 管理 |
| `Sources/Yours/App/TitleTypography.swift` | 内置文档七档字重注册、标题语义字号与显示/测量共用字体；不进入持久化 |
| `Sources/Yours/App/AppTheme.swift` | SwiftUI 与原生绘制共用的主题色，默认系统蓝；不属于文档持久化属性 |
| `Sources/Yours/App/YoursApp.swift` | 生命周期、存储实例、Mac 新建命令 |
| `Sources/Yours/App/NativeRecordGallery.swift` | NSCollectionView / UICollectionView 复用、SwiftUI 卡片宿主与滚动恢复 |
| `Sources/Yours/App/RecordGalleryLayout.swift` | 摘要高度缓存、最短列几何与可见区域索引 |
| `Sources/Yours/App/WorkspaceView.swift` | 平台入口、记录卡片、记录编辑器及格式菜单 |
| `Sources/Yours/App/MobileWorkspaceView.swift` | iOS/iPadOS 自适应双栏、分类选择、卡片与编辑导航栈、长按整理与移动分类 sheet |
| `Sources/Yours/App/MacWorkspaceView.swift` | Mac 底板功能栏、圆角卡片内的 Inbox 入口/内容原生分栏、编辑与窗口级新建命令上下文 |
| `Sources/Yours/Editor/Native/NativeRichTextEditor.swift` | NSTextView / UITextView 桥接、选区、输入事件和平台交互 |
| `Sources/Yours/Editor/Features/EditorFeatureRegistry.swift` | 不可变输入上下文、feature 协议、语义命令与优先级 registry |
| `Sources/Yours/Editor/Features/StandardEditorFeatures.swift` | quote、task/list、code block、inline 和 Markdown shortcut 等内置输入 feature |
| `Sources/Yours/Editor/Native/NativeTextAttributes.swift` | TextKit 绘制、字体映射、原生属性与持久化属性转换 |
| `Sources/Yours/Editor/ParagraphEditing.swift` | `DocumentTypography` 排版配置、独立行内强调、整段格式操作、旧语义字体迁移、待办标记切换 |
| `Sources/Yours/Editor/MarkdownShortcut.swift` | 单次输入触发的局部转换规则，UTF-16 范围 |
| `Sources/Yours/Markdown/MarkdownFormatting.swift` | 常用 Markdown 导入与语义导出，非全部富文本的无损编解码器 |
| `Sources/Yours/Markdown/MarkdownFile.swift` | Markdown 文件类型与 SwiftUI 文档读写适配 |
| `Sources/Yours/Model/Note.swift` | 记录值模型、纯文本投影和兼容解码 |
| `Sources/Yours/Model/TableData.swift` | 表格 Codable 模型、行列操作、Markdown 表格交换与纯文本投影 |
| `Sources/Yours/Editor/Native/NativeTableView.swift` | 表格附件尺寸、原位单元格控件与行列菜单 |
| `Sources/Yours/Editor/Native/NativeTableOverlay.swift` | 表格控件与代码块工具栏随原生文本布局定位、复用与移除 |
| `Sources/Yours/Editor/RichTextClipboard.swift` | 结构化选区剪贴板编解码与粘贴时的块标识去重 |
| `Sources/Yours/Editor/CodeBlockEditing.swift` | 代码语言、别名、块范围、缩进和基础词法高亮规则 |
| `Sources/Yours/Editor/CodeFormatting.swift` | 独立 actor 中的离线 Prettier / JavaScriptCore 格式化；资源随 App 打包 |
| `Sources/Yours/Persistence/NoteStore.swift` | 身份、标题、搜索投影、JSON 读写和失败恢复 |

当前自定义 `CodeLayoutManager: NSLayoutManager` 绘制行内代码、代码块背景和引用竖线，走 TextKit 1 布局路径；不能称作 TextKit 2 编辑器。macOS 以滚动容器内边距限制正文宽度，滚动条留在编辑区右边。

原生输入先捕获为 `EditorInputContext`，再由 `EditorFeatureRegistry` 依次匹配 feature。feature 只返回 `EditorInputCommand`；
`NativeRichTextEditor.Coordinator` 统一执行文本修改、输入属性、选区、撤销和发布。新增 feature 必须显式确定优先级，并覆盖与 quote、task、list、code 等已有 feature 的组合行为。

输入事件经过平台 delegate、`Coordinator.intercept` 与局部转换规则，再发布富文本和选区。组合输入期间跳过转换；格式操作和快捷转换注册撤销。显示字体通过平台倍率放大，写回时还原，避免反复桥接导致字号增长。

原生正文用 LF 表示段落边界、U+2028 表示段内换行；正文段后距由 `DocumentTypography.bodyParagraphSpacing` 控制。Markdown 交换在导入时消费块间的一个分隔空行，保留多余空段和代码块内部空行；导出恢复分隔语法，连续列表或引用保持紧凑。已有富文本中的换行不自动迁移，存储与结构化剪贴板直接保留这些字符。

代码块的 `CodeHeaderOverlayController` 承载语言、自动换行和复制操作，代码文字继续留在同一 TextKit 文本存储中。布局委托在首行预留工具栏高度，避免文档开头忽略段前距时发生遮挡。语言编辑按块 ID 定位，通过原生编辑器的撤销路径修改，并保留正文选区。`CodeTextContainer` 为不换行代码段提供按内容测量的独立行宽，`CodeLayoutManager` 按块 ID 保存临时换行与水平偏移、裁剪文字并绘制滚动位置指示；Mac 横向滚轮和移动端横向拖动修改该偏移。普通正文宽度不变，光标移动时滚动到可见范围；这些显示状态不写入 `Note.richText`，重建编辑视图后恢复自动换行。

代码块默认总高度限制为 400 pt；当前编辑视图按块保存临时展开状态，展开后按完整内容高度布局，收起重置纵向偏移。工具栏由自然内容高度决定是否提供展开入口，边缘不绘制渐变。`CodeLayoutManager` 保留自然行位置与块内纵向偏移，行片段只贡献其与可见窗口相交的高度；文字、UTF-16 选区及撤销仍使用原存储，绘制裁剪在工具栏下方。原生方向键移动前先显示相邻视觉行，折叠光标变化后按需滚动；修改、窗口宽度变化和换行切换后钳制偏移。Mac 滚轮和移动端 pan 按主要方向路由至当前块，共用滚动条渐隐状态。平台手势、输入法和选择操作仍需按验证矩阵实际检查。

## 编辑命令与临时浮层

`EditorCommands.swift` 定义共享的格式动作、可搜索目录、slash 查询和语义转换；`NativeEditorControls.swift` 只承载临时界面。Mac 使用编辑器窗口的非激活子面板，UIKit 的 slash 候选放在键盘附件区，选区格式接系统编辑菜单，以共享命令替换系统格式子菜单并保留复制、粘贴等建议操作。单选区与多选区 delegate 入口汇入同一路径。复杂选项的输入焦点由平台宿主管理。

`NativeRichTextEditor.Coordinator` 持有会话和内容修订号，验证记录身份与目标范围，再统一执行文字、选区、输入属性和撤销快照。页面的格式按钮通过 `EditorCommandBridge` 调用此路径，不为同一动作重复注册模型层撤销。选区链接面板冻结原目标；文档或修订变化后拒绝过期动作。目录、搜索词和面板状态不持久化，已提交编辑仍通过原有富文本绑定和保存路径写入。

正文行首或空格后的 slash 输入在文字提交后识别，组合输入期间隐藏候选且不消费候选键。粘贴与撤销不自动唤起。整段命令和行内命令保持不同作用域；对已完成任务重复设置相同段落类型不重置完成状态，代码块只允许完整范围转换。显示与操作规则见 [DESIGN](../DESIGN.md#slash-与选区工具栏)，验证范围见 [验证](verification.md#slash-与选区格式回归)。

## 数据与恢复

正式版应用标识为 `app.yours.editor`、存储目录为 `Yours`；Debug 标识为 `app.yours.editor.development`、固定开发目录为 `YoursDevelopment`。有效测试 UUID 使用独立的 `YoursUITests/<UUID>` 目录。路径和偏好统一由 `AppStorage` 决定，旧开发文档保留原位，不自动迁入正式资料库。应用偏好、富文本与剪贴板自定义标识统一使用 `yours`。更名不迁移开发期 Weave 数据。

`Note.richText` 是主数据，`text` 为正文搜索和摘要使用的纯文本投影，`Note.title` 是独立持久化的纯文本字段，搜索同时匹配标题和正文。缺少标题分离标记的旧记录将首个非空行迁移为标题，并从正文中移除该行；其余富文本属性保持不变。迁移后的记录保存分离标记，后续不再根据正文猜测；显式空标题保持为空。`NoteAttributeScope` 保存 SwiftUI 属性、`CodeStyleAttribute`、`CodeLanguageAttribute`、`ParagraphStyleAttribute`、`QuoteAttribute`、`TaskStateAttribute`、`InlineEmphasisAttribute`、`ListMarkerAttribute` 与 `TableAttribute`。代码属性区分 inline 与带 ID 的 block；段落属性保存标题、列表、任务和代码等内部角色，引用通过独立布尔属性叠加，因此可以包住这些段落类型。引用竖线和默认次要文字色只在原生显示层生成，不写入 Markdown 内容或用户颜色；旧引用的 `│ ` 前缀与旧 quote 段落角色在读取时迁移。任务完成状态独立保存且正文不包含 checkbox 占位字符，旧任务的 `☐ / ☑` 前缀在读取时迁移为该属性。行内强调以独立标志保存加粗和斜体，经过原生桥接、存储和结构化剪贴板保留，避免与标题自身的字重混淆。无序圆点和有序编号由 `ListMarkerAttribute` 保存，原生布局在正文左侧绘制，正文与选区不包含标记字符；缩进仍使用 Tab，不是完整结构化列表树。显示标记按三层循环；嵌套有序列表根据父项边界重新计数，主级保留指定起始值，Markdown 仍使用数字编号。旧记录仅对明确的列表角色迁移旧文本标记，先校验旧纯文本投影再迁移，重复读取不再剥离正文开头的数字。

读取旧记录时，仅将明确保存为旧 `.title` / `.title2` / `.title3` 的语义字体迁移为对应标题角色，并补齐旧标题的行内强调。无法确认语义的显式字号保留原样；显示布局不再通过字号阈值猜标题。新标题按角色和独立强调投影到当前排版配置。

表格在富文本中保存一个 U+FFFC 附件字符和矩形 `TableData` 属性，首行为表头；平台附件和 SwiftUI 单元格控件按表格 ID 重建，控件在输入时复用。纯文本投影展开单元格，解码时校验展开内容；旧记录不含表格时投影不变。表格不使用截图存储，也不使用独立弹窗编辑。每格当前为单行纯文本，超宽表格横向滚动，不支持合并单元格和富文本单元格。

代码语言随块保存，导出包含语言标签；高亮目前为 Swift、JavaScript、TypeScript、Python、JSON、Shell 的基础词法规则，未知语言保留标签。显示颜色通过临时标记从持久化映射中排除，颜色不成为 Markdown 语义。代码不执行。

正文选区同时写入应用自有 Codable 格式、系统 RTF 和纯文本；同一应用内粘贴优先恢复引用、Todo、标题和行内强调等完整语义，跨应用则使用标准 RTF 或纯文本。表格的纯文本回退为 Markdown，粘贴时重建表格和代码块 ID，避免两个副本共用输入视图；代码的纯文本回退保留原文字面量。外部纯文本粘贴在解析后存在已支持 Markdown 语义时复用同一插入、撤销和发布路径；普通文本及外部 RTF/HTML 回退原生粘贴，代码上下文不解析 Markdown。单元格内部编辑继续使用平台剪贴板。

稳定 UUID 在创建时生成；本地新建记录插入数组开头，云端合并后按更新时间排序，浏览视图按最后编辑时间排序。分类操作不修改编辑时间。各窗口独立持有导航状态，Mac 新建命令作用于当前窗口且不指定分类，移动端沿用当前分类。Mac 启动进入首页空态，文档入口进入 Inbox 全部文档总览；Inbox 仅为导航入口，不改持久化分类；紧凑移动端从分类导航开始。移动端以一个 NavigationSplitView 和 detail NavigationStack 适配窗口尺寸，UUID 路径驱动编辑页，不在横竖屏切换时创建另一套编辑器。

存储由应用实例持有，Observation 驱动 UI。修改先立即进入主线程内存状态，再由串行 actor 在主线程外编码、原子写入 `AppStorage.directory` 下的 `notes.json`，写入端按修订号拒绝过期快照。场景离开 active 时等待最新快照写完；Mac 正常退出有未保存内容时通过 terminateLater 等待写入，失败取消退出。实际目录受平台沙箱影响，三套资料库与云端行为见[存储与同步](storage-and-sync.md)。

记录的 `folderID` 是记录级字段，不属于 `NoteAttributeScope`；旧记录缺字段时默认未分类。`NoteFolder` 独立保存空分类。`notes.json` 当前以 `version: 1 / folders / notes` 单个原子快照存储；读取兼容旧记录数组，首次实际修改才写新版。未知版本、缺字段、重复身份、空分类名和悬空分类引用均禁止覆盖原文件。旧版本 App 不支持新版容器，不应交替写同一目录。

字体持久化经 `PortableFontAttribute`：保留可编码的 SwiftUI 语义字体，平台字体改存带版本的名称、字号、字重与 traits 描述，不嵌入字体文件。内置思源宋体在按名称重建前注册到当前进程；原生桥接写回内置字族时使用命名字体。旧平台字体仍走兼容读取，下次保存迁移；无法解码的内容不降级为纯文本。`NoteSwiftUIAttributes` 保留原 SwiftUI scope 的其余属性，笔记、本地同步基线及结构化剪贴板共用该边界。冲突判断和副本内容摘要比较解析后的字体信息，忽略平台 provider 身份差异；真实字体、字号及其他富文本属性的修改仍参与冲突判断。引入此格式的开发版需要在参与同步的设备上一起更新，旧构建不能交替写入。

旧数据缺少 richText 时读取为普通文本；已有富文本损坏、为空值或与投影不一致时禁止覆盖。读取失败保留原文件并禁写；保存失败保留当前进程的内存修改，可重试。持久化测试使用隔离临时目录，不能用用户真实记录进行破坏性验证。

## 未实现与限制

- CloudKit 可选同步已有源码接入；Mac 开发签名、独立容器授权、真实私有数据库上传和重启后读取已验证；生产环境与双设备验收仍待完成。详见[存储与同步](storage-and-sync.md)。
- JSON 仍是整库快照，虽然编码和写盘不阻塞输入，长文档与大记录库的内存复制和文件体积仍待评估。
- 列表缩进和勾选属于文本编辑能力；有序列表回车递增编号，但修改中间项目尚不自动重编号，没有独立待办模型或完整嵌套语义。
- 无删除 / 回收站、画板、导图、附件缓存；云端文档冲突保留两版，尚无冲突整理界面。Markdown 导入创建新记录，导出不改变主数据。
- 多平台编译不能证明触控、输入法、辅助功能或多设备同步通过。

现状依据上述源码；验证方法见[验证清单](verification.md)。

## 测试基础设施

`scripts/check_coverage.py` 读取 LLVM 覆盖率，按核心、桥接、全源码执行门禁；`.github/workflows/ci.yml` 运行单测和两端 UI 测试。Debug App 支持 UUID 命名的隔离测试存储，Release 使用正常存储。具体命令、门槛与限制见[验证清单](verification.md)。

记录瀑布流由 macOS 的 `NSCollectionView` 和 iOS/iPadOS 的 `UICollectionView` 按可见区域创建、复用 SwiftUI 卡片宿主。共享 `RecordMasonryLayout` 按最短列排布，保留记录顺序与 UUID。`RecordGalleryLayout` 使用当前 SwiftUI 字体解析得到的 Core Text 字体测量标题和最多 600 字的摘要；按记录、列宽和排版设置缓存高度，正文未变的记录可跨排序和编辑页返回复用缓存。列宽或系统字号变化会重新测量；这与数据分页独立，笔记仍整库载入。

布局保存全量轻量矩形及各列的纵向索引，可见区域查询按列二分查找，不在每次滚动时全量扫描或测量。首次布局和宽度变化仍需 O(n) 文本测量与几何准备，不承诺大库首屏恒定耗时。滚动偏移写入非观察属性，避免每帧触发工作区筛选与排序；切换分类和搜索通过显式重置代数归零，打开记录返回后恢复像素偏移。移动端卡片通过外层导航路径打开记录，不依赖独立宿主中的 NavigationLink 环境。

收藏功能及模型字段已删除。解码时忽略旧文件中的 `isFavorite` 字段，下次保存不再写出该字段；记录内容和分类不受影响。


### 代码语言与格式化（现状）

基础词法高亮覆盖 26 种语言：Swift、JavaScript、TypeScript、JSX、TSX、Python、JSON、Shell、HTML、XML、CSS、SCSS、Less、SQL、YAML、Markdown、GraphQL、Go、Rust、Java、Kotlin、C、C++、C#、Ruby、PHP。它识别关键词、字符串、注释、数字及常见标签/属性，不承诺 IDE 级语义、所有方言或嵌套语言解析。

格式化覆盖 JavaScript、TypeScript、JSX、TSX、JSON、HTML、CSS、SCSS、Less、YAML、Markdown、GraphQL。Prettier 3.9.9 standalone 与所需插件固定版本打包在 `Resources/CodeFormatting`，许可证和第三方声明同目录保留。Swift Package 与 Xcode target 都复制该目录；运行不依赖网络、Node.js 或用户机器的命令行工具。

`CodeFormatting` actor 独占 JavaScriptCore VM，代码作为字符串传给解析器，不执行用户代码。所有插件本地加载，关闭嵌入语言格式化；每种解析器有 Promise 返回完成、幂等和尾部段落边界测试。统一 2 空格、LF，单块最多 200,000 UTF-16 单元，超过时保留原文并提示。

按钮任务由 SwiftUI 生命周期管理；完成后先检查取消、组合输入、存储实例及目标块完整快照，再通过 coordinator 的原生撤销路径替换当前块。格式化期间修改代码或语言会丢弃过期结果。相邻块、引用属性与正文边界保留，外围选区跟随长度变化，块内选区偏移钳制到合法组合字符边界。


编辑页通过 `@State ToastPresenter` 持有短暂反馈；原生编辑器向 `onToast` 回调传递消息，代码块格式化错误和剪贴板写入失败共享该出口。Toast 不访问文本存储、不操作焦点、不保存到笔记。每条消息具有独立 ID，替换后重建卡片并取消旧任务；关闭操作核对 ID，避免旧计时器误关新提示。格式化错误保留详细诊断供用户主动展开。

浮层光标：Mac Toast 按钮通过非拦截的 `PointingHandRegion` 声明实际点击热区；原生 `ReadingMacTextView.cursorUpdate` 先检查同窗口的可见浮层区域，避免正文 tracking 事件用 I 形光标覆盖按钮手型。区域弱引用管理，隐藏、移除和不同窗口不参与命中。

Mac 精简工作区不再持有分类、搜索与导入状态；左栏直接绑定当前笔记 ID，显示全部记录。共享 NoteEditorView 只在 iOS 构建顶部格式/Markdown 菜单、字符统计与格式栏；Mac 保留标题、原生正文、链接编辑和保存错误反馈。分类持久化模型保留，用于已有数据兼容和移动端，不因移除 Mac 入口清理数据。


## 应用偏好与本地化

`AppPreferences` 由 App 持有并注入窗口，使用 UserDefaults 持久化外观、语言与默认关闭的 iCloud 开关，不进入 notes.json。普通 Debug 使用固定开发 suite，有效 `YOURS_UI_TEST_SESSION` 使用独立测试 suite；两者与正式偏好隔离，自动测试不允许访问 CloudKit。

`preferredColorScheme` 在窗口内容根部应用主题，跟随系统时传 nil。活动语言在进程生命周期内固定，语言 Picker 使用待确认值；取消不写偏好，确认先等待本地保存，保存或重启准备失败回退。Mac 由 `AppLanguageRestart` 等待旧进程正常退出后通过 LaunchServices 重新打开同一 App；退出保存失败会取消重启助手并回退语言，不使用并行实例。iOS/iPadOS 确认后手动重新打开，当前界面仍显示活动语言。正常开发／正式进程在启动时同步应用域 `AppleLanguages`，Mac 重启后从已保存偏好采用目标语言。测试重启使用绑定 bundle 路径、60 秒有效且读取后删除的一次性 UUID 凭据，保留同一隔离资料库和偏好；仅 macOS Debug App 读取，Release 与 Swift Package 忽略。隔离测试 suite 不改日常应用域的系统菜单语言。

`Resources/zh-Hans.lproj` 和 `Resources/en.lproj` 维护同键 Localizable.strings，并注册到 Xcode 与 Swift Package。所有资源键使用稳定的英文语义标识（如 `note.create`、`settings.title`），不以中英文显示文案作为 key。SwiftUI 静态文案直接传入语义 key 并使用 locale 环境；原生菜单和错误通过 `L10n.string` 读取活动语言资源。带参数文案集中在 `L10n` 的具名方法中，通过显式 key 和 `defaultValue` 的类型化插值解析；中文 defaultValue 仅提供参数及缺失资源时的回退，不是查询 key。字符数和记录数的 `.stringsdict` 使用相同语义 key，保留英文单复数规则。独立宿主的表格和代码操作栏显式注入 locale。用户内容不作为本地化 key；带参数的提示整体翻译，避免拼接句子。添加文案时同步两份资源并检查参数类型与顺序。

MacWorkspaceNavigation 以页面和可选文档 UUID 为访问位置，通过 select/openNote/createNote 统一推进历史；后退与前进直接切换历史位置，避免再次入栈。历史属于窗口内存状态，不写入笔记存储。

文档字体资源位于 `Resources/Fonts`，Swift Package 与 Xcode target 都复制整个目录及 OFL 许可证。`BundledSerifFont` 首次使用时通过 Core Text 注册完整七档字重到当前进程，缺失或注册失败会记录诊断并回退系统标题字体；原始版本、来源与 SHA-256 见该目录 README。独立标题按 `DocumentTypography.titleSize` 使用 SemiBold 显示，卡片按当前平台 headline 解析字号后使用 Medium供显示和高度测量，保持字号变化时缓存失效。

非代码系统字族及系统中文 UI 回退字族在 `NativeTextAttributes.displayFont` 中投影到思源宋体，保留原字号倍率；等宽与显式自定义字族跳过 family 替换。中文 UI 回退字族通过公开 Core Text API 按简体、繁体、香港语言解析；不将公开的自定义 PingFang 字族一并替换。旧中文斜体可能只保存独立强调标志，显示时同时读取该标志与原字体 traits。`setFont` 将投影前 CTFont 保存在临时原生属性 `yoursStoredFont`，`rich` / `storedFont` 恢复原字体、字重与斜体；该属性不属于 `NoteAttributeScope`。输入属性、快捷格式、删除恢复及撤销快照必须同时维护显示字体与原字体，避免把已显示的宋体写回笔记。章节标题根据段落角色显示 SemiBold，显式加粗强调仍显示 Bold，原存储字重保持；斜体通过显示矩阵呈现，各字重使用同版本真实字体；表头在投影前选择字重。旧笔记无需迁移，卡片摘要与操作界面不受此映射影响。

_Last updated: 2026-09-28 — 记录正文显示字体的可逆桥接与资源边界。_

`AppTheme.documentBody` / `documentHeading` 为按外观与对比度解析的原生动态颜色，供 SwiftUI 标题、表格和原生正文共用。`NativeTextAttributes.rich` 排除这些默认显示色，段落角色切换重新选择默认色；显式自定义颜色不参与主题投影。

_Last updated: 2026-09-28 — 补充 Slash 与选区格式入口、共享事务和验证边界。Evidence: `EditorCommands.swift`, `NativeRichTextEditor.swift`, `EditorCommandContractTests.swift`, `NativeCommandTests.swift`._

## 公式与 Mermaid

`RenderedContent` 持久化类型、UUID 和源码，使用单个 U+FFFC 的 `RenderedContentAttribute` 存入 `Note.richText`。`NoteAttributeScope` 与原生桥接共同保存属性；搜索和摘要投影为源码。剪贴板私有格式复制对象时生成新 UUID，Markdown 输出恢复 `$…$`、`$$` 或 `mermaid` 围栏。

`DocumentContentRenderer` 使用随包分发的 KaTeX/Mermaid，在非持久化 WKWebView 中离线渲染并生成图像，最多同时两个实例，缓存最近 32 个结果。临时尺寸和像素不进入笔记数据。macOS 为 WebKit 子进程启用 network-client entitlement；页面只允许本地导航且 CSP 禁止网络，KaTeX 禁止 trust，Mermaid 使用 strict；源长度、展开次数、边数和图像尺寸有限制。渲染失败显示可点击的错误占位，源码仍可编辑和导出。

`RenderedContentOverlayController` 把 SwiftUI 渲染视图放在 TextKit 附件的位置；单击选中对象并编辑源码。公式浮层通过临时附件更新正文预览，关闭时通过 coordinator 提交一次撤销；Mermaid 使用 sheet，取消不写回、应用注册撤销。`RenderedContentDraft` 隔离草稿与持久化，以 250 ms 防抖更新预览，取消和代次校验阻止过期结果覆盖；错误保留上次有效图像。`SourceCodeEditor` 使用原生文本输入实现基础高亮、缩进与 Mermaid 行号，组合输入期间不刷新源码或高亮。异步完成后按对象身份与源码重新查找位置，移除、切换文档或过期编辑不能写回旧位置。脚本与资源更新说明见 `scripts/document-rendering/README.md`。
