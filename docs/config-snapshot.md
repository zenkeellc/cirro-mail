# 配置快照（导入 / 导出）

App 把「哪些设置算配置、怎么读成条目、怎么写回本机」收在一个读写口里，传输与加密由扩展模块负责。这份文档写给两类人：想接这个接缝的扩展作者，以及排查「某台设备的设置没同步」的自己。取舍写在被改的那几个文件的注释里，这里只记口径。

## 谁在用它

核心在 `lib/main.dart` 的 `BootstrapGate` 里挂 `RoamConfigHostImpl`：位置在 `attachDraftStore(...)` 之后、建 `ProviderScope` 之前 —— 那一刻本地库、prefs、钥匙串都已就绪，而扩展的启动钩子**已发起**（`bootstrapAll` 是 unawaited，host 挂上时可能仍在跑），它们要么等 `roamConfigHostReady`，要么安静降级。消费方**必须** `await AppExtensionRegistry.instance.roamConfigHostReady` 再取 host，不要直接判可空的 `roamConfigHost` getter：`onBootstrap` 早于挂 host，那一刻它必然是 null。公开版没人读它（注册表里没有扩展），这一段不启动任何东西、不改任何行为。

## 条目形状

一条 `RoamConfigItem` 就四个字段：`key`（稳定身份）、`group`（粗分类，给合并策略用）、`secret`（敏感项标记）、`data`（内容）。`data` **不做强类型解码** —— 条目不会被整条丢弃；核心只读已知子字段，未知子字段由消费方保管。

| key | group | data | 来源 |
|---|---|---|---|
| `app.schema` | `meta` | `{v:1}` | 版本位；写回时忽略 |
| `app.appearance` | `appearance` | `{themeMode, themePackId, locale}` | `cm_theme_mode` / `cm_theme_pack` / `cm_locale` |
| `app.compose` | `compose` | `{sendDelaySeconds}` | `cm_send_delay_seconds` |
| `sig:<email>` | `compose` | `{text}` | `cm_signatures` 一条 |
| `phrases:<email>` | `compose` | `{items:[{id,name,text}…]}` | `cm_phrases` 一组 |
| `app.reading` | `reading` | `{pollSeconds, prefetchFull, notifyEnabled, notifyBanner, quietTrackingPixels, externalAllowedHosts}` | 六个 `cm_*` |
| `app.ai` | `ai` | `{settings:{…}, source}` | `cm_ai_settings` 原样 JSON / `cm_ai_source` |
| `instance:<instanceKey>` | `instances` | `{baseUrl, name, email, colorIndex, sort}` | `profiles` 一行（不含 `userId`/`userName`/`serverTitle`/`ossBase`/`needsLogin`） |
| `secret.instance:<instanceKey>` | `secrets` | `{value}`（token 原样字符串） | 钥匙串 `token_<profileId>`；只在 `includeSecrets: true` 导出，**永不经过 `applyItems`** |
| `secret.ai_key` | `secrets` | `{value}`（API key 原样字符串） | 钥匙串 `ai_api_key`；同上 |

`<email>` 用存储里的**逐字原样**（大小写敏感），消费方不得归一化；只有 `<instanceKey>` 里的 email 会全小写。

`<instanceKey>` = `roamInstanceKey(...)` = `<scheme>://<host[:port]>|<email>`：全小写、丢掉整条路径、默认端口不写、没写协议按 https 补；**没有登录邮箱就是 null**（这种实例不参与漫游）。**本机 `profiles.id` 是 UUID，不能当身份** —— 换设备就换，拿它算 key 只会在别的设备上凭空造出假实例；能对上「同一台实例」的只有地址 + 登录邮箱。

## 写回的规矩

`applyItems` **只写认得的 key**：`app.schema`、扩展自己的条目、未来版本的条目一律安静忽略（不抛、不丢别人的数据）。敏感项永远不走 `applyItems` —— 读值走 `readSecret`、恢复走 `writeSecret`（空串 = 删掉），两者由消费方逐个向用户要授权；导出时要带值才传 `includeSecrets: true`。跨设备**删除**只走 `deleteItems`，且只覆盖 `sig:<email>` / `phrases:<email>`：`app.*` / `instance:*` / `secret.*` 一律忽略 —— 别的设备删条目不该清掉本机实例与登录态。实例按 `instanceKey` 去重：已存在时只改展示字段（备注名 / 色标 / 排序），不动 `userId` / `userName` / `needsLogin` 这类登录与探测的产物，也不删本机多出来的实例。写回与删除都会触发 [变更流](#变更流)，所以消费方写回期间**要自己抑制回传**；核心侧必须幂等（把导出的原样写回去，快照不变）。

## 变更流

全 App 只有一条「本机配置变了」的信号（`SettingsChangeSignal`，由 `bootstrap()` 建一份共用实例）：prefs setter、实例增删改、token 写入都汇到上面，host 的 `changes` 就是它。消费方拿到通知后**自己防抖 / 去重**再决定要不要上传，核心不替它攒批。Riverpod 这一侧由 `prefsRevisionProvider` 做镜像：设置类 provider 的 `build()` 同步读 prefs，prefs 变了它们自己不会知道，watch 这个版本号才能在「扩展把漫游结果写回来」时重算 —— 写信页的签名 / 常用语与设置页的「写邮件」一节都靠它刷新。

## 不漫游的东西

这些刻意不进快照：当前选中的实例、引导标记、分栏宽度、窗口几何、侧栏展开态、更新检查时间、推广位记录、`push_*` 三件套与设备配对码、推送开关与已登记邮箱、诊断开关、云草稿开关（隐私同意逐设备）、license/device 元数据、本地缓存、AI 用量。前几项是每台设备的界面习惯（同步过去只会互相打架），后面的要么是凭据 / 计费状态，要么本来就按设备算 —— 把它们塞进快照会让「换个设备登录」变成「把别人的设备和额度一起搬过来」。
