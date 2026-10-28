/// 全局常量与默认值。所有「可调」的东西集中在这里，避免散落。
class AppDefaults {
  const AppDefaults._();

  /// 引导页那个输入框的预填值。**刻意留空**：开源仓库里不替使用者的部署
  /// 地址做主，自建的人第一次启动就填自己的 `https://<你的域名>/api`
  /// （输入框有一条 `https://example.com/api` 的占位提示）。
  ///
  /// 做发行版的人可以在这里填自己的地址，或者用
  /// `--dart-define=...` 注入 —— 与下面几个常量同一个路子。
  static const String defaultBaseUrl = '';

  /// 列表分页大小。服务端上限：/email/list 50、/account/list 30。
  static const int mailPageSize = 50;
  static const int accountPageSize = 30;
  static const int starPageSize = 50;

  static const Duration connectTimeout = Duration(seconds: 15);

  /// /email/latest 在 Web 端配的是 35s 超时，这里保持一致。
  static const Duration receiveTimeout = Duration(seconds: 35);

  /// 发信可能带几十 MB 的 base64 附件。
  static const Duration sendTimeout = Duration(minutes: 10);

  static const Duration downloadTimeout = Duration(minutes: 30);

  /// 收信轮询的间隔。服务端 `websiteConfig.autoRefresh` 只作建议
  /// （线上为 0 = 未配置），真实值一律以用户设置为准。
  ///
  /// **只有一档**：先前是「活跃 30s / 空闲 10min」两档（用户正看着的实例
  /// 用短间隔），但两档对用户是同一个问题的两个答案 —— 「多久检查一次
  /// 邮件」。合成一档之后，用户调的就是这个数本身。
  static const Duration pollDefault = Duration(minutes: 5);

  /// 设置页下拉里的档位（1 分钟起、封顶 1 小时）。
  ///
  /// 与仓库里「发送延迟」那处同一个理由：离散档位，滑块能拖出来的 47 分钟
  /// 没有任何意义。而 1 分钟这个**下限**是产品定的 —— 比它更激进（旧的
  /// 下限是 3s、档位里有 10s / 30s）意味着手机一直醒着，省下的那点新鲜度
  /// 换不回电池。落在档位之外的历史值会被 [PrefsStore] 夹进区间。
  static const List<Duration> pollChoices = <Duration>[
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 3),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 20),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(minutes: 60),
  ];

  static Duration get pollMin => pollChoices.first;
  static Duration get pollMax => pollChoices.last;

  /// 把任意一个间隔收进 [pollChoices] 里最接近的一档。
  ///
  /// 设置页那个 `DropdownButton` 必须是这个用途：它的 `value` 只要不在
  /// `items` 里就会直接抛断言，而存过的值完全可能不在档位里 —— 旧版本存过
  /// 30 秒 / 10 分钟，区间边界的值也可能被手改的 prefs 顶出档位。平局
  /// （比如 4 分钟，离 3 和 5 一样近）取靠前那一档，纯粹是让结果确定。
  static Duration nearestPollChoice(Duration value) {
    var best = pollChoices.first;
    for (final choice in pollChoices) {
      if ((choice - value).abs() < (best - value).abs()) best = choice;
    }
    return best;
  }

  /// 失败退避（网络类失败 3s → 6s → 12s → … 封顶 60s）。
  ///
  /// [SyncEngine.currentInterval] 取「用户设的间隔」与退避的**较大值**，
  /// 所以实际生效的重试间隔不会短于用户选的那一档。
  static const Duration pollBackoffStart = Duration(seconds: 3);
  static const Duration pollBackoffMax = Duration(seconds: 60);

  /// 单封邮件附件总量软上限。真正卡死的是 worker 的 128MB 内存与发信服务商的单封限制。
  static const int attachmentTotalSoftLimit = 20 * 1024 * 1024;

  /// 应用内预览单个附件的字节上限。
  ///
  /// 与 [attachmentTotalSoftLimit] 取同一个数不是巧合：文本、CSV 与 Office
  /// 解析都要把整份字节读进内存（`archive` 解压后还会更大），20MB 是这套
  /// 纯 Dart 解析器在这几个平台上验得动的量级。**超限不是错误** ——
  /// 这类附件只是不提供「预览」，打开 / 分享 / 另存为一律照旧。
  ///
  /// 注意它与「下载」无关：下载是流式落盘的，不受这里约束。
  static const int attachmentPreviewLimit = 20 * 1024 * 1024;

  /// 服务端硬限制：/email/send 的 attachments 与内嵌图都不超过 10 个。
  static const int attachmentCountLimit = 10;
  static const int inlineImageCountLimit = 10;

  /// 通知深链找不到邮件时最多往回翻几页。
  static const int deepLinkMaxPages = 5;

  /// 写完点「发送」之后，真正发出去之前留的后悔时间。
  ///
  /// `/email/send` **没有定时发送也没有幂等键**，所以这段时间完全在客户端做：
  /// 信只躺在 `OutboxEntries` 里，到点才由发件箱时钟发出去。0 = 立即发送。
  static const Duration sendDelayDefault = Duration(minutes: 1);

  /// 后悔窗口的上限。再长用户会以为发丢了（而且这封信在发件箱里躺得越久，
  /// 附件文件被系统清掉、实例被删掉的概率越高）。
  static const Duration sendDelayMax = Duration(minutes: 10);

  /// 每轮同步最多补拉几封正文（见 `EmailRepository.backfillBodies`）。
  ///
  /// 补正文一个请求只拿一封（服务端没有「按 emailId 批量取」的接口），
  /// 开太大冷启动那一轮会打几十个请求；20 封在首屏之内，用户看到的是
  /// 灰点一排排消失，而不是一次全亮。
  static const int bodyBackfillPerRound = 20;

  /// 「立即全部同步」一次最多补几封。
  ///
  /// 与 [bodyBackfillPerRound] 不是一回事：那个是**自动**轮询每轮愿意花的
  /// 预算（后台悄悄跑，越小越省流量），这个是用户**明确按了按钮**之后一次
  /// 能补的上限。给得比它大一个量级，是因为用户按下按钮时已经表达了
  /// 「我现在就要这些信」；但不能无限大 —— 每封都会真的打请求（正文一个，
  /// 每个附件再各一个），200 封配上大附件能跑十几分钟。
  static const int syncBatchLimit = 200;

  /// 侧栏那个「总数」多久算过期（见 `MailboxTotalsProbe`）。
  ///
  /// 展示用的数字，变化频率本来就低；每次展开都重探的话，一个装着几十个
  /// 邮箱的实例每展开一次就打几十个请求 —— 而用户往往只是滑过那一眼。
  static const Duration mailboxTotalTtl = Duration(minutes: 10);

  /// 探测一个实例里各邮箱总数时的并发上限。
  ///
  /// 批内并发，实例之间串行：同一个实例的邮箱共用一条连接，串行发就等于
  /// 把延迟叠起来；而实例之间再并发就是替用户决定「哪台实例更该占带宽」，
  /// 没有那个必要。
  static const int mailboxTotalProbeConcurrency = 3;

  /// 推送中转（mail-push）的默认地址。自建部署可用
  /// `--dart-define=PUSH_RELAY_URL=...` 覆盖。
  static const String pushRelayUrl = String.fromEnvironment(
    'PUSH_RELAY_URL',
    defaultValue: 'https://push.zenkee.com',
  );

  /// 部署者在本机打包时注入的实例位 id 与**设备配对码**（见
  /// `sections/push_section.dart`）。
  ///
  /// ## 这两个默认值可以内置，webhookSecret 不可以
  ///
  /// 设备配对码（中转端的 `instances.device_code`）是**App 自己的凭证**，
  /// 权限只有「注册设备 / 读自己登记过的邮箱的事件」，设计上就是可公开的
  /// —— 内置进安装包不再是事故，最坏结果只是「谁都能给自己装一份 App」。
  /// 它只在创建时回显一次，App 端也只在密钥库里存一份。
  ///
  /// **绝不要把 webhookSecret 内置进来**：那是实例后台要填的密钥，权限大
  /// 得多（能伪造 webhook 往 events 里灌数据），装进客户手机等于把它公开。
  /// 见 `docs/push-setup.md`（「两把钥匙」那一节）。
  ///
  /// 默认空串：开源仓库里不带任何配置，部署者自己 `--dart-define`。
  static const String pushInstanceId = String.fromEnvironment(
    'PUSH_INSTANCE_ID',
    defaultValue: '',
  );
  static const String pushPairingCode = String.fromEnvironment(
    'PUSH_PAIRING_CODE',
    defaultValue: '',
  );

  static const String userAgent = 'cloud-mail-flutter';
}
