# 存储与 iCloud 同步

## 实现与验收边界

源码已接入可选 CloudKit 同步、本地合并与设置。已用开发签名验证独立容器授权、产物内容器标识、设置开关、真实私有数据库上传与 Mac 重启后读取；Console 可直接读取 `library-v1` 的快照附件。Mac 上传的测试文档已在真实 iPhone 出现，手机编辑也已传回 Mac；修复平台字体再次编码的 `invalidFont` 后，用户确认 iPhone 立即同步不再报错。以上为基本双向链路证据，生产环境和完整双设备异常场景验收仍未完成。未配置的构建保持本地使用，iCloud 开关禁用且说明原因。

`AppStorage` 为应用级数据边界，不能用“每次预览生成一个测试 UUID”替代开发资料库。

| 用途 | App ID | Application Support 内目录 | 偏好 | 云端容器 |
| --- | --- | --- | --- | --- |
| 正式 Release | `app.yours.editor` | `Yours/notes.json` | 应用默认域 | `iCloud.app.yours.editor` / Production |
| 日常 Debug | `app.yours.editor.development` | `YoursDevelopment/notes.json` | `YoursDevelopment.preferences` | `iCloud.app.yours.editor.development` / Development |
| Debug 自动测试 | Debug App | `YoursUITests/<UUID>/notes.json` | 同 UUID 独立 suite | 禁止连接 |

普通开发预览反复启动使用固定资料库；Release 忽略测试环境变量。Swift Package 调试运行也使用开发目录，不连接 CloudKit。工作树共享相同开发 App ID 时会共享开发资料库，需复用同一个实例，不同时启动多份写入同一文件。要隔离专项预览，使用独立 bundle ID 并固定复用同一个测试 UUID；该模式禁止云端连接。

Mac 语言重启通过测试目录中的一次性会话凭据继续同一测试资料库和偏好，避免依赖系统重启时可能丢弃的参数。凭据绑定 App bundle 路径，60 秒有效，读取后删除；仅 macOS Debug App 读取，Release 与 Swift Package 忽略。测试会话始终禁止 CloudKit 连接。

## CloudKit 概念与空间归属

CloudKit 是 Apple 托管的应用云数据库能力。Yours 当前的个人同步使用用户的私有数据库，无需为这条同步链路单独租服务器或部署自建数据库；开发者负责 App 接入、容器、签名、schema 和同步行为，用户只需在应用中选择是否开启同步。

| 名称 | 在 Yours 中的含义 |
| --- | --- |
| Container（容器） | 为 App 配置的云端数据边界，通过 App ID 和签名授权访问；本项目开发版与正式版使用不同容器 |
| Environment（环境） | 每个容器各自包含 Development 和 Production，分别维护 schema 与记录 |
| Private Database（私有数据库） | 每位用户在容器中拥有各自的私有数据，存储计入该用户的 iCloud 额度 |
| Record Type / schema（记录类型与结构） | 开发者定义可保存的数据结构；当前类型为 `YoursLibrary`，字段 `payload` 为 Asset |
| Record（实际记录） | App 写入的用户数据；当前每位用户以 `library-v1` 保存一个整库快照，并非每篇笔记各一条记录 |

私有数据库占用用户自己的 iCloud 空间；公共数据库占用 App 的 CloudKit 额度，两者的容量归属不同。当前 Yours 使用私有数据库，用户没有登录 iCloud 或额度不足时，同步可能失败，本地保存仍需独立工作。额度依据 Apple 的 [privateCloudDatabase](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) 和 [publicCloudDatabase](https://developer.apple.com/documentation/cloudkit/ckcontainer/publicclouddatabase) 文档。

## 设置与同步行为

独立任务 MVP 与笔记共用 `notes.json` 和 CloudKit 快照，格式升级为 v2，包含 `todos`。旧数组和 v1 可迁入，新保存使用 v2；旧构建无法解码 v2，应停止加载而非覆盖。任务详情打开期间延迟相关远端修改，独立任务修改可合并，同一任务并发修改暂停并保留两端，当前没有冲突解决 UI。任务回收站满 15 天清理内容，保留身份删除标记防止旧设备复活；下文关于文档无删除传播的限制仍然成立。真实任务双设备 CloudKit 链路尚待验收，既有笔记同步证据不能替代。

- 开关默认关闭，按资料库保存。开启后合并本地和当前 Apple 账户的私有云端内容；关闭后保留两端已有内容，不执行删除。
- 应用前台激活且开关开启时检查一次，此后每 30 秒检查；也可点击立即同步。当前没有后台 push/系统后台任务、增量同步或删除传播。
- 已进入网络传输的操作不能通过关闭开关撤销；取消后不继续应用旧返回或开始后续上传。再次开启会重新合并。
- 当前以一个 `YoursLibrary` record（固定 ID `library-v1`）的 `payload: Asset` 保存全库快照；不在 iCloud Drive 放置共享 JSON。适用于当前本地整库模型，网络与编码成本随资料库增长；后续大库应升级为逐记录增量同步。
- 下载后验证版本、身份唯一性和分类引用。以最近成功同步快照为共同基线进行三方合并；独立修改合并，同一文档并发修改保留两个版本，副本使用内容派生的稳定 UUID，重试不反复复制。副本保留原题和内容，当前尚无专门的冲突整理界面。
- 分类按 UUID 合并；同一分类两端同时改名时采用云端名称。尚无分类删除模型。
- 合并先进入本地保存链路，确认落盘成功再上传；云端写入使用 `ifServerRecordUnchanged`，版本冲突不盲目覆盖，下一次同步重新获取并合并。同步失败保留内容和错误，不更新成功时间。
- 云端修改涉及当前已打开的文档时，等待所有窗口离开该编辑页后再合并，保护组合输入、选区与撤销；没有远端变更的本地文档仍可上传。
- `cloud-sync.json` 保存账户绑定、上次成功快照与时间，和笔记一起保存在各自资料库中，不是可清理缓存。切换 Apple 账户后暂停上传，要求切回原账户；当前不支持将同一资料库迁到另一账户。
- Mac 正常退出等待最新本地写入；失败则保持应用打开。强制退出、断电与移动端后台终止不保证最后一次正在进行的写入已完成。

## 图片与附件的空间管理（已确认方向，尚未实现）

当前尚不支持图片与附件，本次不实现按需下载、缩略图、空间清理或相关设置；等接入图片与附件时一并设计和实现。当前继续使用本地完整保存与整库同步，不提前添加无实际作用的开关。

- 文档正文和未来的待办文本完整保留本地，供离线编辑、快速列表展示及本地搜索使用；暂不因长期未访问或归档而卸载正文。独立任务 MVP 已接入，图片和附件仍为后续范围。
- 图片保留轻量缩略图，原图按需下载；大附件在使用时下载。列表所需的标题、目录等信息常驻本地，浏览不依赖原图或附件下载。
- 提供「保持图片和附件下载」，说明为「保留原图和附件的本地副本，离线时也可使用。」开启后不自动释放对应本地副本；未开启时可按需下载，并允许释放已确认上传成功且无待上传修改的原图和附件。具体作用范围与自动清理规则届时设计。
- iCloud 同步与下载保留策略分开：前者负责云端同步，后者负责本地空间占用。释放本地副本不删除云端内容或文档入口；未上传内容不能清理，同步不替代备份。
- 归档暂只用于内容整理，不自动决定下载状态；不在当前范围引入正文卸载或按访问时间淘汰正文。
- 引入云端独有的原图或附件后，关闭 iCloud 同步的流程需明确未下载内容的可用性，并设计「下载完整副本后关闭」与「直接关闭」的处理、失败及取消行为；不能暗示关闭后所有内容均已离线可用。当前整库模式无需提前增加此流程。

实现时需将图片和附件从整库快照中独立存储，分别管理缩略图、原始文件、同步状态与本地下载状态，并验证离线、上传失败、下载中断、保持下载及清理边界。这是后续实现要求，不代表现有 schema 已支持这些能力。

## 配置真实 CloudKit

1. 在 Xcode 的 Signing & Capabilities 中为 Debug / Release 选择属于自己的 Apple Developer Team。普通 Apple 账户或 Personal Team 是否支持 CloudKit，以该 Team 实际能力和 provisioning 为准。
2. 为两个 App ID 启用 iCloud / CloudKit，分别创建并授权上述两个容器。在 Signing & Capabilities 的 iCloud 配置中将容器加入当前 App 的列表，等待描述文件更新；只在 entitlements 中写标识不代表描述文件已绑定容器。两个容器不能指向同一份数据。
3. App target 的 Debug / Release 都使用 `Config/Build.xcconfig`，其中可选加载不提交的 `Config/CloudKit.local.xcconfig`。本机开发文件按下例设置；不存在该文件时仍可运行不连接云端的 CI / 本地构建。显式云端构建也可用 `-xcconfig Config/CloudKit.xcconfig DEVELOPMENT_TEAM=<team-id>`。

   ```xcconfig
   DEVELOPMENT_TEAM[config=Debug] = <your-team-id>
   YOURS_ICLOUD_CONTAINER[config=Debug] = iCloud.app.yours.editor.development
   CODE_SIGN_ENTITLEMENTS[config=Debug] = Config/CloudKitDebug.entitlements
   ```

   Team 不写入受版本控制的项目文件。
4. `Config/AppInfo.plist` 显式保存 `YoursCloudContainerIdentifier` 并展开容器 build setting；任意自定义 `INFOPLIST_KEY_*` 不能作为该键已进入产物的证据。配置文件指定对应 `Config/CloudKitDebug.entitlements` / `CloudKitRelease.entitlements`；Debug 使用 Development，Release 使用 Production。不要用覆盖 App ID 的方式把开发版连到正式容器。Mac 运行时还核验签名中的容器和环境；ad-hoc 构建不提供同步。
5. 首次同步前，在开发容器显式创建 `YoursLibrary` 类型及 `payload` Asset 字段，再运行应用。已观察到空 schema 的新容器在首次 fetch 时返回服务端 HTTP 500，补齐 schema 后返回正常的记录不存在结果并可完成上传；不能把 HTTP 500 当作空资料库覆盖。正式容器需要相同 schema。正式环境 schema 部署属于发布动作，需要单独授权；代码改完不会自动发布 schema。
6. 真实设备开启 iCloud Drive / 允许应用使用 iCloud，以有授权的签名构建验证。两台设备必须使用同一个容器和环境。

使用 Apple 的 [CloudKit 容器配置说明](https://help.apple.com/xcode/mac/current/en.lproj/devcae40ccb9.html) 和 [schema 部署说明](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)。

## 正式环境准备（尚未完成）

开发环境的真实上传、Mac 重启读取及 Mac/iPhone 基本双向同步已验证。正式容器的配置、schema 部署和正式签名构建仍待完成；双设备异常场景尚未完整验收。本节记录后续步骤，不代表已授权执行发布。

1. 创建正式容器 `iCloud.app.yours.editor`，为正式 App ID `app.yours.editor` 启用 CloudKit 并绑定该容器，确认签名描述文件包含正确授权。
2. 在**正式容器自己的 Development 环境**创建 `YoursLibrary` 类型与 `payload: Asset` 字段，核对应用需要的字段和索引。
3. 在同一正式容器中执行 `Deploy Schema Changes`，将 schema 从 Development 部署到 Production。开发专用容器 `iCloud.app.yours.editor.development` 的 schema 不会因此自动复制到另一个容器。
4. 核对 Release 产物的容器为 `iCloud.app.yours.editor`、环境为 Production，再验证签名、开启同步、离线恢复、重启及同一 Apple 账户的双设备行为。

**不需要预先为每位用户手工创建记录。** 用户开启同步后，App 会先读取并合并已有云端内容，再将本地内容保存到该用户的私有数据库；不存在 `library-v1` 时，由 App 创建该记录。开发者准备的是容器、授权和 schema，用户数据由 App 按需写入。

部署 schema 只复制记录类型、字段和索引，不复制开发环境的记录。因此，开发验证文档不会随 schema 部署进入正式用户的资料库。依据 Apple 的 [schema 部署说明](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)。正式环境的部署属于单独的发布动作。

## 已有开发文档

本次不搬动、合并或删除旧资料库。以前用正式 App ID 启动的开发文档仍在旧沙箱 `Yours` 或 `YoursUITests/<UUID>`；历史专项 App ID 有独立沙箱。新 Debug 标识与目录首次启动为空，不能解释成旧文件被删除。恢复时先确认来源、备份和目标，再显式导入；不能自动把测试样本上传正式云端。

## 验证

- Swift Testing：资料库及偏好隔离、固定开发目录、无效测试 UUID 拒绝打开其他资料库、Release 忽略测试变量、本地重建恢复、三方合并、重复冲突去重、坏数据拒绝、关闭期间丢弃返回、账号变更禁上传、失败后重试。
- Mac UI：设置页开关与状态、测试会话禁用云端、原生编辑后重启恢复；正常 Command-Q 退出也要检查最后输入。
- 真实 CloudKit 待验证：双设备首轮合并、同时离线编辑后恢复、断网/限流、应用重启、账户退出与切换、关闭期间已有请求结束，以及开发/正式容器交叉隔离。未完成这些检查前，不称为生产同步验收通过。
