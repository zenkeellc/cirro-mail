// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Cirro Mail';

  @override
  String get servers => '服务器';

  @override
  String get addServer => '添加服务器';

  @override
  String get addInstance => '添加实例';

  @override
  String get serverAddress => '服务器地址';

  @override
  String get serverAddressHint => 'https://example.com/api';

  @override
  String get testConnection => '测试连接';

  @override
  String get testing => '测试中…';

  @override
  String connectedTo(String title) {
    return '已连接：$title';
  }

  @override
  String get addAndSignIn => '添加并登录';

  @override
  String get login => '登录';

  @override
  String get logout => '退出登录';

  @override
  String get logoutKeepServer => '退出登录（保留服务器）';

  @override
  String get removeServer => '移除服务器';

  @override
  String removeServerConfirm(String name) {
    return '移除「$name」及其本地缓存的邮件？';
  }

  @override
  String get email => '邮箱';

  @override
  String get password => '密码';

  @override
  String get signingIn => '登录中…';

  @override
  String get nickname => '备注名';

  @override
  String get save => '保存';

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get confirm => '确定';

  @override
  String get retry => '重试';

  @override
  String get copied => '已复制';

  @override
  String get copy => '复制';

  @override
  String get all => '全部';

  @override
  String get aggregateInbox => '聚合';

  @override
  String get markAllRead => '全部标记已读';

  @override
  String get markRead => '标记已读';

  @override
  String get markUnread => '标记未读';

  @override
  String get refresh => '刷新';

  @override
  String get settings => '设置';

  @override
  String get diagnostics => '诊断';

  @override
  String get inbox => '收件箱';

  @override
  String get sent => '已发送';

  @override
  String get starred => '星标';

  @override
  String get star => '标星';

  @override
  String get unstar => '取消星标';

  @override
  String get newMail => '新邮件';

  @override
  String newMailSummary(String name, int count) {
    return '$name：$count 封新邮件';
  }

  @override
  String get notifyBanner => '应用内横幅提醒';

  @override
  String get notifyBannerHint => '关闭后照样收信（列表会更新），只是不再弹通知。';

  @override
  String get pushTitle => '后台推送（FCM）';

  @override
  String get pushShort => '推送';

  @override
  String get pushHint => 'App 退到后台或被系统冻结时，靠推送中转把新邮件提醒送到手机。不配也能用 —— 只是后台不再提醒。';

  @override
  String get pushRelayUrl => '中转地址';

  @override
  String get pushRelayUrlHint =>
      '自建的 mail-push Worker，形如 https://push.example.com';

  @override
  String get pushInstanceId => '实例位 id';

  @override
  String get pushInstanceIdHint => '部署者在中转端 /admin/instances 开的那个 id';

  @override
  String get pushPairingCode => '配对码';

  @override
  String get pushPairingCodeHint => '开实例位时只显示一次，丢了就重新轮换';

  @override
  String get pushDeviceId => '设备号';

  @override
  String get pushDeviceIdHint => '本机自动生成、并且带实例位前缀，不需要你改。排查时有用：中转端就是靠它认这台设备的。';

  @override
  String get pushEnable => '开启后台推送';

  @override
  String get pushEnabledHint => '只影响后台提醒。前台收信、轮询、应用内提醒都不受影响。';

  @override
  String get pushRegister => '登记这台设备';

  @override
  String get pushUnregister => '退订';

  @override
  String get pushTestOk => '中转连上了';

  @override
  String get pushRegistrations => '中转端记着的邮箱';

  @override
  String get pushRegistrationsEmpty => '这台设备在中转端还没有登记任何邮箱';

  @override
  String get pushUnsupported =>
      '这个平台没有 FCM 实现（只有 Linux / Windows 是这样，那两端的后台提醒靠 App 在运行时轮询）。';

  @override
  String get pushNotConfigured => '还没有填中转配置，当前只能靠 App 在运行时收信。';

  @override
  String get pushNoFirebaseConfig =>
      '这份构建里没有 Firebase 配置文件（google-services.json / GoogleService-Info.plist），FCM 不可用。需要你先在 Firebase 建项目再重新构建。';

  @override
  String get pushRelayFcmMissing => '中转端没有配 FCM 服务账号，推送发不出去。';

  @override
  String get pushWebhookHint =>
      '把下面两条填进**你那个 cloud-mail 实例**后台的「Webhook 推送」里，再把开关打开。这一步只能你自己做：中转端不认识实例的登录体系，替不了。';

  @override
  String get pushWebhookUrl => 'Webhook 地址';

  @override
  String get pushWebhookSecret => 'Webhook 密钥';

  @override
  String get pushWebhookNoSecret => '还没有配对码，拿不到密钥';

  @override
  String get pushCopy => '复制';

  @override
  String get pushCopied => '已复制';

  @override
  String get pushChecking => '自检中…';

  @override
  String get pushSelfCheckOk => '配对码与地址都对上了';

  @override
  String get pushSelfCheckSecretBad => '配对码不对 —— 这个实例位的密钥已经轮换过，去重新要一个';

  @override
  String get pushSelfCheckUrlBad => '地址填错了 —— 要带上 /<实例位>/webhook 这一段';

  @override
  String get pushSelfCheckNoEventYet =>
      '配置看着没问题，但这个位还没有真的收到过来信 —— 记得去实例后台保存并打开开关。';

  @override
  String pushSelfCheckGotEvent(String time) {
    return '最近一次收到 webhook：$time';
  }

  @override
  String get pushNeedLoginFirst => '先在上面把配对码和实例位填好，自检才知道要问哪一条。';

  @override
  String get pushLimits => '限制（先说清楚，免得白等）';

  @override
  String get pushLimit1 => '只覆盖外部来信：站内互发、以及别的客户端发出的信不触发推送，只有轮询能收到。';

  @override
  String get pushLimit2 => '实例若把收信规则设成「按规则收信」，webhook 完全不触发。';

  @override
  String get pushLimit3 => '推送里只有元数据（发件人/主题/验证码），正文仍由 App 带 token 去实例拉。';

  @override
  String get pushLimit4 => '中转端能看到所有实例的来信元数据 —— 自建的话就是你自己。';

  @override
  String get pushAdvanced => '高级';

  @override
  String pushPageStepOf(int index, int total) {
    return '第 $index 步 / 共 $total 步';
  }

  @override
  String get pushPageBack => '上一步';

  @override
  String get pushPageNext => '下一步';

  @override
  String get pushPageDone => '完成';

  @override
  String get pushPageRecheck => '重新检查状态';

  @override
  String get pushPageStatusTitle => '推送现在通不通？';

  @override
  String get pushPageStatusBody =>
      '三件事互相独立：这个平台支不支持、三条值填没填全、这台设备在中转端登记上没有。缺任何一件，App 不在时都不会有提醒。';

  @override
  String get pushPageStatusPlatform => '这个平台支持 FCM';

  @override
  String get pushPageStatusOk => '没问题';

  @override
  String get pushPageStatusConfigured => '中转的三条值填全了';

  @override
  String pushPageStatusRegisteredCount(int count) {
    return '已登记 $count 个';
  }

  @override
  String get pushPageStatusOff => '总开关是关着的 —— 下面这些都不会发生。';

  @override
  String get pushPageStatusGo => '去把开关打开';

  @override
  String get pushPageValuesTitle => '把三条值填进来';

  @override
  String get pushPageValuesBody =>
      '三条都从中转端来：地址是那个 Worker 的域名，实例位是它给你开的位置，配对码只在开位那一刻显示一次。';

  @override
  String get pushPageValuesSave => '保存这三条值';

  @override
  String get pushPageValuesSaved => '已保存';

  @override
  String get pushPageValuesKeep => '配对码只在开实例位时显示一次，之后两端都读不回来。丢了只能重新轮换。';

  @override
  String get pushPageValuesProvision => '中转是我部署的 —— 现开一个实例位';

  @override
  String get pushPageEnableTitle => '打开「后台推送」';

  @override
  String get pushPageEnableBody => '这个开关只管 App 不在前台时要不要提醒；前台收信、轮询、应用内提醒都不受影响。';

  @override
  String get pushPageEnableOff => '关掉开关会顺手退订，中转不再往这台设备推。';

  @override
  String get pushPageEnrollTitle => '登记这台设备';

  @override
  String get pushPageEnrollBody =>
      '把每个邮箱绑到这台设备的 FCM token 上。启动时也会自动登记一次，所以这一步主要是用来确认「真的登记上了」。';

  @override
  String get pushPageEnrollPermission => '第一次点登记时，系统会问一次通知权限 —— 就是这一步。';

  @override
  String get pushPageEnrollBlocked => '先去第 ② 页把三条值填上，再去第 ③ 页打开开关。';

  @override
  String get pushPageEnrollUnsubHint => '退订会把本机在中转端的注册全删掉，之后不再收到推送。';

  @override
  String get pushPageWebhookTitle => '去实例后台打开 Webhook 推送';

  @override
  String get pushPageWebhookBody => '这是唯一必须在另一个网站上做的一步，也是最常被漏掉的一步。';

  @override
  String get pushPageWebhookAdminAsk => '这个 cloud-mail 实例是你在管吗？';

  @override
  String get pushPageWebhookAdminYes => '是，我去后台填';

  @override
  String get pushPageWebhookAdminNo => '不是，发给管理员';

  @override
  String get pushPageWebhookAdminOtherHint => '把下面这段话复制下来，发给管这个实例的人。';

  @override
  String get pushPageWebhookRelayCopy => '复制要转达的话';

  @override
  String pushPageWebhookRelayMessage(String url, String code) {
    return '麻烦在 cloud-mail 实例后台的「Webhook 推送」里填上地址 $url、密钥 $code，并把那一栏的开关打开。这样新邮件才能推到我的手机上。';
  }

  @override
  String get pushPageWebhookStatus0 =>
      '提醒：那个开关在库里叫 webhookStatus，0 才是「启用」，字段名与直觉相反 —— 收不到推送时第一嫌疑永远是它。';

  @override
  String get pushPageWebhookConfirm => '我已经在实例后台填好这两条，并把 Webhook 推送开关打开了';

  @override
  String get pushPageWebhookConfirmed => '已确认过。上面的地址或配对码改过之后，这一步要重新确认一次。';

  @override
  String get pushPageWebhookUnconfirmed =>
      '你在另一个网站上做的事，App 看不到，所以这一步得你自己点一下那个勾；不点的话它会一直显示成「没做」。';

  @override
  String pushPageWebhookEvidence(String time) {
    return '中转端已经真的收到过 webhook（$time）—— 这一步通了，不需要再确认。';
  }

  @override
  String pushPageCheckRememberedAt(String time) {
    return '上次检查是通过的（$time），上面的值也没改过 —— 不用重新检查也会记着。';
  }

  @override
  String get pushPageCheckNever => '还没检查过。点上面那个按钮问一次，结论会一直记着。';

  @override
  String pushRefreshed(int count) {
    return '已刷新：中转端记着 $count 个邮箱';
  }

  @override
  String get pushRefreshedEmpty => '已刷新：中转端还没有登记任何邮箱';

  @override
  String get pushRegistering => '登记中…';

  @override
  String get pushUnregistering => '退订中…';

  @override
  String get pushRefreshing => '刷新中…';

  @override
  String get pushPageCheckTitle => '检查这条链路';

  @override
  String get pushPageCheckBody =>
      '一次问清四件事：中转连不连得上、它有没有配 FCM、这个配对码对不对、实例后台里那个地址填对没有。';

  @override
  String get pushPageCheckAction => '检查这条链路';

  @override
  String get pushPageCheckStale => '上面的值改过了 —— 再检查一次才会得到新的结论。';

  @override
  String get pushPageCheckFcmOk => '中转端配了 FCM 服务账号';

  @override
  String get pushPageNotesTitle => '先说清楚的几件事';

  @override
  String get pushPageNotesBody => '后台推送刻意做得很窄：只覆盖外部来信，其余的照旧靠轮询。';

  @override
  String get pushPageNotesTurnOff => '怎么关掉';

  @override
  String get pushPageNotesTurnOffBody => '回到第 ③ 页把开关关掉即可，App 会顺手退订。';

  @override
  String get pushPageNotesSwitchSlot => '换一个实例位会怎样';

  @override
  String get pushPageNotesSwitchSlotBody => 'App 会自动把旧实例位上的注册退掉，不用你手动清理。';

  @override
  String get pushPageDocsHint => '完整命令与故障排查见仓库里的 docs/push-setup.md。';

  @override
  String get compose => '写邮件';

  @override
  String get composeSectionSignatures => '签名';

  @override
  String composeSignatureFor(String email) {
    return '$email 的签名';
  }

  @override
  String get composePhrases => '常用语';

  @override
  String composePhrasesFor(String email) {
    return '$email 的常用语';
  }

  @override
  String get composePhraseName => '名字';

  @override
  String get composePhraseText => '内容';

  @override
  String get composeSignatureEmpty => '还没有邮箱 —— 先登录一个实例';

  @override
  String get composeSnippetsHint => '签名与常用语按邮箱地址存，换实例也还在';

  @override
  String get noMailbox => '没有可用邮箱';

  @override
  String get needAccountPerm => '该账号没有「account:query」权限，无法列出全部邮箱，仅显示主邮箱。';

  @override
  String get emptyList => '暂无邮件';

  @override
  String get loadFailed => '加载失败';

  @override
  String get attachmentUnavailable => '附件不可用';

  @override
  String get serverUnreachable => '服务器不可达';

  @override
  String get sessionExpired => '登录已失效，请重新登录';

  @override
  String get sessionExpiredHint => '可能是其他设备登录把本次会话挤掉了（同一账号仅保留 10 个会话）。';

  @override
  String get needsLogin => '需要重新登录';

  @override
  String get syncNow => '立即同步';

  @override
  String get close => '关闭';

  @override
  String get switchMailbox => '切换邮箱';

  @override
  String get pickMail => '选择一封邮件';

  @override
  String get syncing => '正在同步';

  @override
  String lastSync(String time) {
    return '上次同步 $time';
  }

  @override
  String get pollInterval => '检查邮件间隔';

  @override
  String get pollIntervalHint => '多久收一次新邮件（1 分钟 – 1 小时）。越短越及时，也越费电。';

  @override
  String minutesCount(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String get notifications => '通知';

  @override
  String get notifyEnabledHint => '关闭后停止轮询收信，也不再提醒新邮件；已收到的邮件仍可正常阅读。';

  @override
  String get clearCache => '清理缓存';

  @override
  String get unnamed => '（未命名）';

  @override
  String get unknown => '未知';

  @override
  String get noSubject => '（无主题）';

  @override
  String get pageNotFound => '页面不存在';

  @override
  String cannotOpen(String uri) {
    return '无法打开：$uri';
  }

  @override
  String get backToInbox => '回到收件箱';

  @override
  String get startupFailed => '启动失败';

  @override
  String get startupFailedHint => '本地数据打不开，App 无法继续。下面是具体原因。';

  @override
  String get keystoreDegraded => '系统密钥库不可用，本次运行只能把登录状态放在内存里，重启后需要重新登录。';

  @override
  String get removeServerLostDrafts => '仍然失败时，可以移除实例后重新添加（未发送的草稿会一并丢失）。';

  @override
  String get instances => '实例';

  @override
  String get noInstances => '还没有实例';

  @override
  String get addFirstInstance => '添加第一个实例';

  @override
  String get editInstance => '编辑实例';

  @override
  String get edit => '编辑';

  @override
  String get instanceName => '实例备注名';

  @override
  String get connectionOk => '连接正常';

  @override
  String get connectionFailed => '连接失败';

  @override
  String get checkAddress => '请检查服务器地址与网络。';

  @override
  String get serverAddressRequired => '请填写服务器地址';

  @override
  String get emailRequired => '请填写邮箱';

  @override
  String get passwordRequired => '请填写密码';

  @override
  String get loginFailed => '登录失败';

  @override
  String signedInAs(String email) {
    return '已登录：$email';
  }

  @override
  String get instanceNeedsLoginHint => '这个实例的登录已失效，重新登录即可 —— 不影响其他实例。';

  @override
  String get noInstancesLoggedIn => '还没有登录的实例';

  @override
  String get polling => '轮询';

  @override
  String get appearance => '外观';

  @override
  String get theme => '主题';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get language => '语言';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get about => '关于';

  @override
  String get version => '版本';

  @override
  String get capabilities => '能力';

  @override
  String get syncStatus => '同步状态';

  @override
  String get intervalLabel => '间隔';

  @override
  String lastSyncAt(String time) {
    return '上次同步：$time';
  }

  @override
  String get consecutiveFailures => '连续失败';

  @override
  String get cursor => '游标';

  @override
  String get endpointSelfCheck => '端点自检';

  @override
  String get rawEnvelope => '原始响应';

  @override
  String get notFoundInWindow => '这封邮件不在已加载的窗口里。';

  @override
  String get openExternally => '用浏览器打开';

  @override
  String get probeNotRun => '未探测';

  @override
  String get send => '发送';

  @override
  String get sendFailed => '发送失败';

  @override
  String get composeTo => '收件人';

  @override
  String get composeSubject => '主题';

  @override
  String get composeBody => '正文';

  @override
  String get removeInstance => '删除实例';

  @override
  String get checkingSession => '正在检查登录状态…';

  @override
  String get setAsCurrent => '设为当前实例';

  @override
  String setAsCurrentOk(Object name) {
    return '已切换到 $name';
  }

  @override
  String removeInstanceConfirm(Object name) {
    return '删除「$name」并清除它的本地缓存邮件？';
  }

  @override
  String signOutConfirm(Object name) {
    return '退出「$name」？未发送的草稿会保留。';
  }

  @override
  String get prefetchTitle => '后台预取完整正文';

  @override
  String get prefetchHint => '列表翻页时顺带拉 full=1，打开邮件更快；关闭可省流量';

  @override
  String get selfCheckHint => '点一下逐个打一遍关键端点，看服务端到底回了什么';

  @override
  String get selfCheckLoginFirst => '先登录 —— 没登录打这些端点只会拿到一串 401';

  @override
  String get noMailboxCache => '还没有邮箱缓存';

  @override
  String get noScheduler => '调度器未运行 —— 没有登录的实例，或用户暂停了轮询';

  @override
  String get allMailboxes => '全部邮箱';

  @override
  String get lastSyncedAt => '上次同步';

  @override
  String get domainList => '域名单';

  @override
  String get siteConfig => '站点配置';

  @override
  String get probedAt => '探测时间';

  @override
  String get fieldTitle => 'title';

  @override
  String get fieldR2Domain => 'r2Domain';

  @override
  String get missingGoesOssApi => '缺失（走 /api/oss/）';

  @override
  String get mailbox => '邮箱';

  @override
  String get toggleInstanceMailboxList => '展开或收起这个实例的邮箱';

  @override
  String get mailboxCountUnknown => '—';

  @override
  String mailboxCountsLabel(int unread, int total) {
    return '共 $total 封，其中 $unread 封未读';
  }

  @override
  String get nicknameHint => '留空时用站点标题或邮箱';

  @override
  String get download => '下载';

  @override
  String get downloading => '下载中…';

  @override
  String get openWith => '用其他应用打开';

  @override
  String get share => '分享';

  @override
  String get saveAs => '另存为';

  @override
  String get preview => '预览';

  @override
  String get attachmentDownloaded => '已下载';

  @override
  String get attachmentDeleted => '已删除本地副本';

  @override
  String get attachmentCache => '附件缓存';

  @override
  String get attachmentCacheHint => '已下载的附件会留在这里，方便离线打开';

  @override
  String get cacheEmpty => '还没有下载过附件';

  @override
  String get pickAttachment => '选择一个附件';

  @override
  String cacheUsage(int files, String size) {
    return '$files 个文件 · $size';
  }

  @override
  String get clearAllAttachments => '清空全部附件';

  @override
  String get clearAllAttachmentsConfirm => '删掉所有已下载的附件？邮件本身不受影响，但下次打开要重新下载。';

  @override
  String get clearProfileAttachments => '清理这个实例的附件';

  @override
  String clearProfileAttachmentsConfirm(String name) {
    return '删掉「$name」已下载的全部附件？';
  }

  @override
  String savedTo(String path) {
    return '已保存到 $path';
  }

  @override
  String get openFailed => '打不开 —— 系统里没有能处理这种文件的应用';

  @override
  String get shareUnavailable => '这个平台没有分享面板，试试「另存为」';

  @override
  String get previewUnsupported => '这种格式不能应用内预览，可以下载后用其他应用打开';

  @override
  String get viewerSource => '源码';

  @override
  String get viewerRendered => '排版';

  @override
  String viewerTruncated(int chars) {
    return '只显示前 $chars 个字符';
  }

  @override
  String viewerEncodingLossy(String encoding) {
    return '按 $encoding 解码，个别字可能显示为 ?';
  }

  @override
  String get viewerMarkdownTooDeep => '嵌套太深，没法按 Markdown 渲染，改看源码';

  @override
  String get viewerFileGone => '文件已经不在了';

  @override
  String get viewerOfficePartial => '此预览不显示图片与版式';

  @override
  String get viewerNotADocument => '这不是 Word / Excel / PowerPoint 文档';

  @override
  String get viewerDocumentBroken => '文档已损坏，读不出来';

  @override
  String get viewerEmpty => '（空文件）';

  @override
  String csvTruncated(int rows, int columns) {
    return '只显示前 $rows 行、$columns 列';
  }

  @override
  String csvDelimiter(String delimiter) {
    return '分隔符：$delimiter';
  }

  @override
  String xlsxSheetsTruncated(int count) {
    return '只显示前 $count 张工作表';
  }

  @override
  String get xlsxPartial => '数字格式已简化，图表与图片未显示';

  @override
  String get xlsxSheetEmpty => '（空工作表）';

  @override
  String pptxSlideOf(int index, int total) {
    return '第 $index 页 / 共 $total 页';
  }

  @override
  String get pptxPartial => '幻灯片只显示了文字，版式、图片与动画未显示';

  @override
  String pptxSlidesTruncated(int count) {
    return '只显示前 $count 页';
  }

  @override
  String get pptxSlideEmpty => '（这一页没有文字）';

  @override
  String get play => '播放';

  @override
  String get pause => '暂停';

  @override
  String get playbackRate => '倍速';

  @override
  String get audioFailed => '这台机器放不了这个文件';

  @override
  String get videoFailed => '这个视频放不了';

  @override
  String get reply => '回复';

  @override
  String get forward => '转发';

  @override
  String get wrote => '写道：';

  @override
  String get composeFrom => '发件邮箱';

  @override
  String get composeSenderSearch => '搜索发件邮箱';

  @override
  String get composeSenderNoMatch => '没有匹配的邮箱';

  @override
  String get composeRecipientsHint => '输入邮箱地址后回车';

  @override
  String get composeBodyHint => '写点什么…';

  @override
  String get composeAttach => '添加附件';

  @override
  String get composeImageTooLarge => '图片太大了（上限 5 MB）';

  @override
  String get composeImageTooMany => '正文里最多 10 张图';

  @override
  String get composeDropFolderIgnored => '文件夹不能当附件';

  @override
  String get composeAiSelectFirst => '先选中要改写的文字';

  @override
  String get composeAiSelectionHasEmbed => '选区里有图片，没法改写';

  @override
  String get composeAiSelectionGone => '原来的选区已经不在了，请重新选中要改写的文字';

  @override
  String get composeAttachmentTitle => '附件';

  @override
  String composeAttachmentCount(int count) {
    return '$count 个附件';
  }

  @override
  String composeAttachmentTotal(String size) {
    return '附件合计 $size';
  }

  @override
  String composeTooManyAttachments(int count) {
    return '附件最多 $count 个';
  }

  @override
  String composeTooManyInline(int count) {
    return '正文内嵌图片最多 $count 张';
  }

  @override
  String composeTooLarge(String limit) {
    return '附件总量超出上限（$limit）';
  }

  @override
  String get composeNoRecipient => '请至少填写一个收件人';

  @override
  String composeBadRecipient(String address) {
    return '收件人地址格式不正确：$address';
  }

  @override
  String get composeEmptyBody => '正文不能为空';

  @override
  String get composeSenderUnavailable => '发件邮箱不可用';

  @override
  String get composeNoMailbox => '没有可用的发件邮箱';

  @override
  String get composeQuotaUnlimited => '发信不限量';

  @override
  String composeQuotaUsed(int used) {
    return '已发 $used 封';
  }

  @override
  String composeQuotaRemaining(int remaining) {
    return '还剩 $remaining 封';
  }

  @override
  String composeQuotaDay(int used, int limit) {
    return '今日 $used/$limit';
  }

  @override
  String composeQuotaTotal(int used, int limit) {
    return '配额 $used/$limit';
  }

  @override
  String get composeQuotaExhausted => '发信配额已用完';

  @override
  String get composeQuotaUnknown => '配额未知';

  @override
  String get composeQuotaBanned => '当前角色被禁止发信';

  @override
  String get composeQuotaInternal => '只能发给站内邮箱';

  @override
  String get composeInternalOnlyHint => '这个角色的配额只允许发给站内邮箱，外部地址会被服务端拒绝';

  @override
  String get composeRemoveRecipient => '移除';

  @override
  String get composeRecentRecipients => '最近联系人';

  @override
  String get sending => '发送中…';

  @override
  String sendingProgress(int percent) {
    return '正在发送 $percent%';
  }

  @override
  String get sendSuccess => '已发送';

  @override
  String get sendQueued => '已放进发件箱，联网后自动发送';

  @override
  String get sendQueuedRetry => '网络不通，已存进发件箱，稍后自动重试';

  @override
  String get sendUnknownResult => '发送结果未知 —— 服务端可能已经收到了。请先在发件箱里确认，再决定是否重发。';

  @override
  String sendAttachmentMissing(String name) {
    return '附件已不在本地：$name';
  }

  @override
  String get sendDraftCorrupted => '草稿已损坏，无法重发';

  @override
  String get sendNow => '立即发送';

  @override
  String get sendLater => '存进发件箱';

  @override
  String get outbox => '发件箱';

  @override
  String get outboxEmpty => '发件箱是空的';

  @override
  String get outboxPending => '待发送';

  @override
  String get outboxSending => '发送中';

  @override
  String get outboxFailed => '发送失败';

  @override
  String outboxAttempts(int count) {
    return '已尝试 $count 次';
  }

  @override
  String outboxLastError(String error) {
    return '失败原因：$error';
  }

  @override
  String get outboxUnknownResultHint => '这封信可能在服务端已经发出去了。确认收件人收到之前，先别重发。';

  @override
  String get outboxRetry => '重试';

  @override
  String get outboxDiscard => '删除';

  @override
  String get outboxDiscardConfirm => '删掉这封还没发出去的信？内容会一起丢掉。';

  @override
  String get draft => '草稿';

  @override
  String get draftSaved => '已存草稿';

  @override
  String draftSavedAt(String when) {
    return '保存于 $when';
  }

  @override
  String get draftDiscard => '丢弃草稿';

  @override
  String get draftDiscardConfirm => '丢弃这封草稿？内容会一起丢掉。';

  @override
  String get draftEmpty => '还没有草稿';

  @override
  String get draftsHint => '草稿只存在这台设备上，和网页版不互通';

  @override
  String get discardChanges => '放弃这些修改？';

  @override
  String get keepEditing => '继续编辑';

  @override
  String get discard => '放弃';

  @override
  String get composeFailedStayHint => '内容还在编辑框里，改完可以直接重试';

  @override
  String get outboxSent => '已发出';

  @override
  String get outboxUnknown => '结果未知';

  @override
  String get drafts => '草稿箱';

  @override
  String get sendSavedToOutbox => '已存入发件箱，稍后自动发出';

  @override
  String get composeLargeAttachmentHint => '大附件是分块上传的，完成前请保持应用在前台';

  @override
  String get close_ => '关闭';

  @override
  String get composeCloseTooltip => '关闭（Esc）';

  @override
  String get composeQuotedAttached => '原邮件会作为引用附在正文末尾';

  @override
  String get mailUnavailable => '无法读取原邮件';

  @override
  String get outboxFlush => '立即全部发出';

  @override
  String get outboxHint => '这里排队的邮件只存在本机，会按顺序一封一封发出。重试会真的再发一次 —— 服务端无法识别重复投递。';

  @override
  String outboxAddressed(String to) {
    return '收件人 $to';
  }

  @override
  String get syncStatusTitle => '同步状态';

  @override
  String get syncStateSyncing => '同步中…';

  @override
  String get syncStateWaiting => '等待中';

  @override
  String get syncStateStopped => '已停止';

  @override
  String syncedCount(int count) {
    return '已同步 $count 封';
  }

  @override
  String unsyncedCount(int count) {
    return '未同步 $count 封';
  }

  @override
  String get unsyncedUnknown => '剩余数量未知';

  @override
  String get unsyncedUnknownHint => '服务端总数只有完整拉过一次列表才知道，所以刚装上时这里是空的。';

  @override
  String syncLastSuccess(String time) {
    return '上次成功：$time';
  }

  @override
  String get syncNeverSucceeded => '还没有成功同步过';

  @override
  String syncFailCount(int count) {
    return '已连续失败 $count 次';
  }

  @override
  String get bodyNotSynced => '正文尚未同步';

  @override
  String pendingMore(int count) {
    return '还有 $count 封未同步 · 点击继续加载';
  }

  @override
  String pendingMorePassive(int count) {
    return '还有 $count 封未同步';
  }

  @override
  String get listLoadingMore => '加载中…';

  @override
  String get listNoMore => '没有更多了';

  @override
  String get listAggregateFooter => '聚合视图按实例分别拉取，滚到底会自动同步';

  @override
  String get syncNowOne => '立即同步';

  @override
  String get syncNowFailed => '这个实例现在没法收信（还没登录或会话已失效），请先重新登录。';

  @override
  String get syncStarted => '已开始同步';

  @override
  String get syncButtonHint => '点一下立即同步 · 长按或右键打开同步页';

  @override
  String get syncingThisMail => '正在同步这封邮件…';

  @override
  String get syncBatchBlocked => '这台实例现在收不了信（还没登录或会话已失效），请先重新登录。';

  @override
  String get pushAutoProvision => '一键开通（部署者）';

  @override
  String get pushAutoProvisionHint =>
      '用部署者的管理员口令为本机开一个中转实例位。口令只用于这一次请求，不落 prefs、不进钥匙串、不写日志。';

  @override
  String get pushAdminToken => '管理员口令';

  @override
  String get pushAdminTokenHint => '只在当前页面可见，离开即清空';

  @override
  String get pushAutoProvisionDone => '已开通，实例位与配对码已填好';

  @override
  String get sendDelay => '发送延迟';

  @override
  String get sendDelayHint => '点「发送」之后等这么久才真的发出去 —— 想反悔的话在这段时间里还来得及取消。';

  @override
  String get sendDelayNone => '立即发送';

  @override
  String sendDelayMinutes(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String queuedNotice(int minutes) {
    return '已加入队列，$minutes 分钟后发送。可以在列表底部的发送队列里取消。';
  }

  @override
  String get sendQueueTitle => '发送队列';

  @override
  String sendQueueCount(int count) {
    return '发送队列 $count 封';
  }

  @override
  String sendQueueIn(int seconds) {
    return '$seconds 秒后发送';
  }

  @override
  String get sendQueueSendNow => '立即发送';

  @override
  String get sendQueueViewAll => '在发件箱中查看全部';

  @override
  String get sendQueueCancelConfirm => '取消这封排队中的邮件？它不会被发出。';

  @override
  String sendScheduled(int seconds) {
    return '$seconds 秒后发送';
  }

  @override
  String get sendQueuedFailed => '加入队列失败 —— 内容还在编辑器里';

  @override
  String sendScheduledMinutes(int minutes) {
    return '$minutes 分钟后发送';
  }

  @override
  String get pushAdminTokenNeeded => '请先填管理员口令';

  @override
  String get pushBuiltInApplied => '已按本次构建的内置配置填好；配对码只存进钥匙串，不写 prefs。';

  @override
  String get aiTitle => 'AI';

  @override
  String get aiSubtitle => '使用你自己的 Key';

  @override
  String get aiPrivacyNotice =>
      '你正文里的片段会被发送到你配置的服务商。Key 存在这台设备的钥匙串里，除发给该服务商的请求之外不会离开它。';

  @override
  String get aiProviderSection => '服务商';

  @override
  String get aiModelSection => '模型';

  @override
  String get aiModelLabel => '模型';

  @override
  String get aiModelHint => '模型名 —— 手填，或用「拉取」挑一个';

  @override
  String get aiBaseUrlLabel => '接口地址';

  @override
  String get aiBaseUrlHint => 'https://api.openai.com/v1';

  @override
  String get aiApiFormatLabel => 'API 格式';

  @override
  String get aiApiFormatOpenai => 'OpenAI 兼容';

  @override
  String get aiApiFormatAnthropic => 'Anthropic';

  @override
  String get aiApiFormatNewapi => 'New API';

  @override
  String get aiBaseUrlHintAnthropic => 'https://api.anthropic.com';

  @override
  String get aiBaseUrlHintNewapi => 'https://你的网关域名 —— 带不带 /v1 都行';

  @override
  String get aiBaseUrlInvalid => '地址要以 http:// 或 https:// 开头';

  @override
  String get aiModelsFetch => '拉取';

  @override
  String get aiModelsFetchNeedKey => '先填 Key 才能拉取';

  @override
  String get aiModelsFetchNeedUrl => '先填接口地址';

  @override
  String get aiModelsEmpty => '这个端点没有模型列表，手动填模型名即可';

  @override
  String aiModelsFailed(String message) {
    return '拉取失败：$message';
  }

  @override
  String get aiTestConnection => '测试连接';

  @override
  String get aiTestNeedModel => '先有模型名才能测试 —— 拉取一个或手填';

  @override
  String aiTestOk(int chars) {
    return '连接正常，模型返回了 $chars 个字';
  }

  @override
  String get aiTestOkNoText => '连接正常（这次只回了思考、没有可见文本 —— 推理模型常常如此，不影响使用）';

  @override
  String aiTestFailed(String message) {
    return '连接失败：$message';
  }

  @override
  String get aiKeySection => 'API Key';

  @override
  String get aiKeyLabel => 'API Key';

  @override
  String get aiKeyStored => '已保存 Key';

  @override
  String get aiKeyNotStored => '还没填过 Key';

  @override
  String get aiKeySave => '保存';

  @override
  String get aiKeyPaste => '粘贴';

  @override
  String get aiKeyPasteEmpty => '剪贴板里没有文本';

  @override
  String get aiKeyClear => '清除';

  @override
  String get aiKeySaved => 'Key 已保存';

  @override
  String get aiKeyCleared => 'Key 已清除';

  @override
  String get aiKeyEmpty => '请先填入 Key';

  @override
  String get aiKeyWhitespace => 'Key 里有空格或换行 —— 检查一下粘贴';

  @override
  String get aiKeyDegraded => '这台设备的钥匙串用不了，Key 存不下来。上面填的这次能用，重启就没了。';

  @override
  String get aiFeaturesSection => '功能';

  @override
  String get aiInlineContinuation => '停笔一会儿，给一句续写建议';

  @override
  String get aiInlineContinuationHint => '每次停笔都会消耗一次调用';

  @override
  String get aiPreflight => '发送前检查';

  @override
  String get aiPreflightHint => '本地规则不花钱；问模型要消耗一次调用';

  @override
  String get aiSubjectSuggest => '标题栏起标题';

  @override
  String get aiSubjectSuggestHint => '主题栏里点一下，直接填一个好标题；已有主题会作为参考';

  @override
  String get aiPolish => '邮件润色';

  @override
  String get aiPolishHint => '写信页右上角点开面板：选语气、写要求，再点「生成」换掉你的正文（引用不动，可以撤销）';

  @override
  String get aiPolishTooltip => '润色全文';

  @override
  String get aiPolishNote => '只润色你自己写的部分，引用的原信一字不动。';

  @override
  String get aiPolishExtraHint => '额外要求（可选），例如：保留专业术语、称呼别改';

  @override
  String get aiPolishGenerate => '生成';

  @override
  String get aiPolishReplaceAll => '替换全文';

  @override
  String get aiPolishIdle => '选好语气、写好要求后点「生成」。';

  @override
  String get aiSubjectEmpty => '先写点正文，才好起标题';

  @override
  String get aiPolishEmpty => '正文还是空的';

  @override
  String get aiPolishFailed => '润色没有返回内容，正文没变';

  @override
  String get aiBudgetSection => '用量';

  @override
  String get aiDailyLimit => '每日调用上限';

  @override
  String get aiDailyLimitHint => '软上限 —— 只提示，不拦。填 0 表示不限。';

  @override
  String aiUsedToday(int used) {
    return '今天已用：$used 次';
  }

  @override
  String get aiUnavailable => '填好 Key 之后这些才会生效';

  @override
  String syncNextIn(int seconds) {
    return '$seconds 秒后';
  }

  @override
  String get unreadMail => '未读邮件';

  @override
  String get filterByMailbox => '按邮箱筛选';

  @override
  String get toggleMailboxList => '展开或收起邮箱列表';

  @override
  String get filterByMailboxHint => '勾一下就生效；至少留一个';

  @override
  String get selectAll => '全选';

  @override
  String unreadCount(int count) {
    return '未读 $count';
  }

  @override
  String get mailboxKeptOne => '至少留一个邮箱';

  @override
  String get syncStageSynced => '已同步';

  @override
  String get syncStageSyncing => '正在同步';

  @override
  String get syncStagePending => '待同步';

  @override
  String get syncStagePendingBody => '缺正文';

  @override
  String get syncStagePendingAttachment => '缺附件';

  @override
  String get syncAllNow => '立即全部同步';

  @override
  String get outboxPendingZero => '没有待发的邮件';

  @override
  String get syncPanelPendingEmpty => '没有待同步的邮件';

  @override
  String get mailTab => '邮件';

  @override
  String instanceCount(int count) {
    return '$count 个实例';
  }

  @override
  String get allInstancesAllMailboxes => '全部实例 · 全部邮箱';

  @override
  String mailboxCountSelected(int count) {
    return '已选 $count 个邮箱';
  }

  @override
  String get syncPanelSyncedEmpty => '还没有已同步的邮件';

  @override
  String attachmentProgress(int done, int total) {
    return '附件 $done/$total';
  }

  @override
  String syncBatchDone(int bodies, int attachments) {
    return '已同步 $bodies 封正文、$attachments 个附件';
  }

  @override
  String get syncBatchNothing => '没有待同步的邮件了';

  @override
  String syncBatchMore(int mails) {
    return '已同步 $mails 封，还有更多待同步（再点一次继续）';
  }

  @override
  String get aiSuggest => 'AI 建议';

  @override
  String get aiSuggestHint => '读一封邮件，告诉你有哪几件事值得做，点一下直接办（回复 / 转发 / 稍后提醒 / 删除…）';

  @override
  String get aiSuggestPanelTitle => 'AI 建议';

  @override
  String aiSuggestReading(int chars) {
    return '已阅读：主题、发件人、正文 $chars 字';
  }

  @override
  String aiSuggestAttachments(int count) {
    return '＋ $count 个附件名';
  }

  @override
  String aiSuggestQuotedDropped(int chars) {
    return '引用部分已裁剪 · 原文 $chars 字';
  }

  @override
  String aiSuggestTruncated(int chars) {
    return '正文过长，只取前 $chars 字';
  }

  @override
  String get aiSuggestFetchingBody => '正在补全正文…';

  @override
  String get aiSuggestAnalyzing => '正在分析…';

  @override
  String get aiSuggestReanalyze => '重新分析';

  @override
  String get aiSuggestRetry => '重试';

  @override
  String get aiSuggestParseFailed => '没能从模型的回答里读出建议：';

  @override
  String get aiSuggestTopPick => '最推荐';

  @override
  String get aiSuggestActionReply => '回复';

  @override
  String get aiSuggestActionForward => '转发';

  @override
  String get aiSuggestActionDelete => '删除';

  @override
  String get aiSuggestActionMarkRead => '标记已读';

  @override
  String get aiSuggestActionMarkUnread => '标记未读';

  @override
  String get aiSuggestActionStar => '加星标';

  @override
  String get aiSuggestActionUnstar => '取消星标';

  @override
  String get aiSuggestActionRemind => '稍后提醒';

  @override
  String get aiSuggestActionNone => '无需处理';

  @override
  String aiSuggestDeleteConfirm(String subject) {
    return '删除「$subject」？';
  }

  @override
  String get remindTitle => '什么时候提醒你？';

  @override
  String get remindToday => '今天 18:00';

  @override
  String get remindTomorrow => '明天 9:00';

  @override
  String get remindNextMonday => '下周一 9:00';

  @override
  String get remindCustom => '自定义…';

  @override
  String get remindPast => '这个时间已经过去了';

  @override
  String remindScheduled(String time) {
    return '会在 $time 提醒你';
  }

  @override
  String selectedCount(int count) {
    return '已选 $count 封';
  }

  @override
  String selectionActionWithCount(String action, int count) {
    return '$action（已选 $count 封）';
  }

  @override
  String get selectionClear => '取消选择';

  @override
  String selectionDeleteConfirm(int count) {
    return '删除选中的 $count 封邮件？此操作不可恢复。';
  }

  @override
  String selectionUnread(int count) {
    return '未读 $count 封';
  }

  @override
  String selectionWithAttachments(int count) {
    return '带附件 $count 封';
  }

  @override
  String selectionTimeRange(String from, String to) {
    return '$from 至 $to';
  }

  @override
  String selectionSelectAll(int count) {
    return '全选（本页 $count 封）';
  }

  @override
  String get selectionStale => '选中的邮件已经不在当前列表里了';

  @override
  String get mailboxTitle => '邮箱管理';

  @override
  String get mailboxAdd => '添加邮箱';

  @override
  String get mailboxAddTitle => '添加邮箱';

  @override
  String get mailboxAddFullAddress => '完整邮箱地址';

  @override
  String get mailboxDomainUnavailable => '域名列表暂不可用，请填写完整地址';

  @override
  String get mailboxAddDisabledByServer => '这台实例关闭了添加邮箱';

  @override
  String get mailboxAddDenied => '该账号没有添加邮箱的权限，请联系管理员';

  @override
  String get mailboxNeedLogin => '需要先登录这台实例';

  @override
  String get mailboxAddVerifyRequired => '这台实例要求人机验证，请到网页端添加';

  @override
  String get mailboxOpenWeb => '在网页端添加';

  @override
  String mailboxRemoveConfirm(String email) {
    return '删除「$email」？这个邮箱里的邮件会被一并永久删除，且无法恢复。';
  }

  @override
  String mailboxRemoved(String email) {
    return '已删除 $email';
  }

  @override
  String mailboxAdded(String email) {
    return '已添加 $email';
  }

  @override
  String get mailboxRename => '改名';

  @override
  String get mailboxPin => '置顶';

  @override
  String get mailboxPrimaryBadge => '主邮箱';

  @override
  String mailboxPrefixTooShort(int n) {
    return '前缀至少 $n 个字符';
  }

  @override
  String get mailboxInvalidAddress => '邮箱地址格式不正确';

  @override
  String get mailboxEmptyName => '名字不能为空';

  @override
  String get mailboxNameTooLong => '名字最多 30 个字符';
}
