import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// `AiApiFormat` 定义在 `ai_provider.dart` 里，而 `ai_settings.dart` 只是 import
// 它、**不 re-export** —— 所以必须显式 show 出来，否则这个文件里
// `AiApiFormat.values` / `DropdownButton<AiApiFormat>` 全部解析不到。
// `AiProvider` 仍然要：Key 校验用它。
import '../../ai/ai_provider.dart' show AiApiFormat, AiProvider;
// `AiModelsOk` / `AiModelsFailed` / `AiTestOk` / `AiTestFailed` 定义在
// `ai_service.dart` 里，它同样不被 re-export —— 这两个模式的解释要显式 import。
import '../../ai/ai_service.dart';
import '../../ai/ai_settings.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/ai_providers.dart';
import '../settings_widgets.dart' show SettingsSectionHeader;

/// 设置 → AI 的正文（**没有自己的 `Scaffold`**）。
///
/// 四项 AI 能力**共用一份设置**，所以只有这一块：API 格式 / 接口地址 / 模型 /
/// Key / 三个开关 / 每日上限。分成四页的结果是「幽灵文本的开关在哪一页」都要
/// 想一下。
///
/// 外壳（`AppBar` / 分类栏 / 窄屏那一页）由 `SettingsScreen` 给 —— 它在
/// 宽屏把这一块内嵌进右栏、窄屏在一个分类页里显示。所以这里返回的是一个
/// `ListView`，不是 `Scaffold`。
///
/// 四条刻意的做法：
///
/// 1. **三样摆在一起：接口地址 / API 格式 / Key。** 它们描述的是同一件事 ——
///    **打到哪个端点、按哪套协议说、怎么认证** —— 所以「服务商」那一段的顺序
///    就是填的顺序。缺任何一样，「拉取」与「测试连接」都置灰并说明差什么
///    （`AiSettings.isUsable` 那三条判据在界面上的落点）。模型栏排在它们
///    **后面**：它是三样齐了之后才谈得上的东西，拉取的结果就写进它。
/// 2. **Key 不经过 `AiSettings`。** 那个对象里只有一个 `hasApiKey` 布尔
///    （Task D1 的设计），真正的字符串走 `aiSettingsProvider.notifier.setApiKey`
///    进钥匙串。于是「Key 会不会被顺手存进 prefs」这件事在类型上就不可能发生。
/// 3. **校验在 `onChanged` 里做**，不等提交。`AiProvider.validateApiKey` 是纯
///    函数，只认「空」和「含空白字符」两种错 —— 而贴 Key 时最常见的错就是
///    尾部带一个换行。做成提交时才报的话，用户会以为「粘贴的键是对的，
///    是你们的软件坏了」。地址栏同理，只判协议前缀。
/// 4. **降级要说出来。** `AiSettingsStore.isKeychainDegraded` 为 true 时，
///    这台设备根本存不住 Key（Linux 没装 libsecret、macOS 钥匙串被锁、
///    插件没注册）。不说的话用户会反复填、反复丢，然后给个一星。
class AiSettingsSection extends ConsumerStatefulWidget {
  const AiSettingsSection({super.key});

  @override
  ConsumerState<AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends ConsumerState<AiSettingsSection> {
  /// Key 输入框的内容。**只在这一次会话里存在** —— 它是唯一的「明文 Key 在
  /// 内存里」的地方，`dispose` 时连着控制器一起丢掉。
  ///
  /// 刻意**不预填**已有 Key：钥匙串里的值读出来只为了回答「有没有」，
  /// 把它摆回输入框等于每次打开设置页都把明文 Key 重新铺一遍。
  final TextEditingController _key = TextEditingController();

  /// Key 那一栏的焦点。**只为了「粘贴」那颗按钮**：按下去先读剪贴板再写框，
  /// 写完之后把焦点还给输入框，用户接着就能改尾巴上的字符（比如 Key 后面
  /// 多带的那串东西），不必再点一次。
  final FocusNode _keyFocus = FocusNode();

  /// 上一次校验的错误码（`AiProvider.validateApiKey` 的返回值），
  /// 翻译成文案是在 `build` 里做的 —— 那儿才拿得到 l10n。
  String? _keyError;

  /// 「拉取」与「测试连接」的进行态与就地结果。两个按钮互不干扰。
  ///
  /// `_modelsNotice` 是**已经拼好的一句整话**（失败时是
  /// `l10n.aiModelsFailed(原文)`，空列表时是 `l10n.aiModelsEmpty`）——
  /// 界面直接显示它，不再套一层前缀，免得「这个端点没有模型列表」被冠上
  /// 「拉取失败：」。
  bool _fetchingModels = false;
  bool _testing = false;
  String? _modelsNotice;
  String? _testError;
  int? _testChars;

  /// 地址栏里**正在敲、还没失焦**的内容。与模型栏那个控制器同一个理由：按钮的
  /// 可用性要跟着打字变，而 `settings.baseUrl` 要等提交/失焦才更新。
  String? _urlDraft;

  /// 模型栏（可编辑的下拉）里的内容。它就是模型草稿的**唯一**来源：
  /// 下拉认它、按钮的可用性也认它，落盘仍然走 `settings`。
  ///
  /// 用控制器而不是一个 `String?` 字段，是因为 `DropdownMenu` 需要把一个
  /// `TextEditingController` 交给它的输入框 —— 这样过滤、选中、手输三条路都
  /// 写在同一份文本上，不会再出现「界面上写着 A、按钮判的是 B」。
  final TextEditingController _model = TextEditingController();

  /// 「拉取」拉回来的模型名。**只活在这一次会话里** —— 它随时可以再拉一次，
  /// 存进 prefs 只会多一份会过期的副本。空列表时下拉里就只有手输那一个值。
  List<String> _models = const <String>[];

  /// 模型下拉的开关。拉取成功后要**自动弹开**，让用户直接挑 —— 否则拉到了
  /// 却什么都没发生，看起来像失败。
  final MenuController _modelMenu = MenuController();

  /// 模型栏的焦点。**失焦就落盘**：手输的名字没有「提交」这个动作，离开这一栏
  /// 就是它的提交（`_TextTile` 用 `onSubmitted` + `onTapOutside` 做同一件事，
  /// 而 `DropdownMenu` 没把 `onTapOutside` 透出来，只能从焦点上听）。
  final FocusNode _modelFocus = FocusNode();

  /// Key 已存过时输入框里显示的掩码。它**不是值**，是「这儿有东西」的提示 ——
  /// 从来没有进过 `_key` 控制器，所以不存在被当成 Key 存回去的可能。
  static const String keyMask = '••••••••';

  /// 地址看起来是个 URL 吗。**只判协议前缀** —— 能不能解析、有没有路径都不查：
  /// 一个代理就能推翻那些假设，而「填了 api.openai.com 少了协议」是最常见的错。
  static bool _urlLooksValid(String raw) {
    final t = raw.trim().toLowerCase();
    return t.startsWith('http://') || t.startsWith('https://');
  }

  /// Key 那半算不算填了 —— **没点过「保存」的那份草稿也算**。用户填完三样直接点
  /// 「拉取」是最自然的动作，要求他先点一次保存才解锁按钮纯属自找的「点了没反应」
  /// （草稿会在 `_prepare` 里先真进钥匙串，所以「算数」不只是让按钮变脸）。
  ///
  /// 草稿被校验拒了（含空白）就按**存过的那份**算：输入框里那个错值反正也用不了，
  /// 指着钥匙串里现成的 Key 更贴合实际。
  bool _keyPresent(AiSettings settings) {
    if (_key.text.trim().isEmpty) return settings.hasApiKey;
    if (AiProvider.validateApiKey(_key.text) != null) return settings.hasApiKey;
    return true;
  }

  /// 模型栏眼下的内容（含还没落盘的草稿）。下拉、按钮、落盘三处都问它 ——
  /// 只有一个来源就不会出现「按钮亮着但发出去的是空模型名」。
  String get _modelDraft => _model.text;

  /// 上一次**由外部**铺进模型栏的值。用来分辨「这次重建是因为用户在敲」
  /// （不动控制器）还是「外面把模型名改了」（要跟上去，比如首读落到
  /// `settings.model` 那一刻）。与 `_TextTileState.didUpdateWidget` 同一条规矩。
  String? _syncedModel;

  /// 外面改了模型名就铺进控制器。**只在外部值本身变了时才动** —— 否则每次
  /// 打字引起的重建都会把用户刚敲的字改回上一个已保存值。
  void _syncModelField(AiSettings settings) {
    if (_syncedModel == settings.model) return;
    _syncedModel = settings.model;
    if (_model.text != settings.model) _model.text = settings.model;
  }

  @override
  void initState() {
    super.initState();
    // 打字要立刻影响「测试连接」的可用性，所以监听控制器自家 setState。
    //
    // **必须只在帧尾排队**：`DropdownMenu` 自己也会写这个控制器（选中一项后
    // 把标签铺回输入框），而那是发生在它 `build` 期间的 —— 那一刻直接
    // `setState` 会撞上「setState() called during build」。挂到帧尾，两种来源
    // （用户敲键、下拉写回）走同一条安全的路。
    _model.addListener(_onModelChanged);
    // 手输的名字靠「离开这一栏」落盘（见 `_ModelRow` 的说明）。
    _modelFocus.addListener(_onModelFocusChanged);
  }

  void _onModelFocusChanged() {
    if (_modelFocus.hasFocus) return;
    if (!mounted) return;
    final typed = _model.text.trim();
    final current = (ref.read(aiSettingsProvider).value ?? const AiSettings()).model;
    if (typed == current) return;
    _save(
      (ref.read(aiSettingsProvider).value ?? const AiSettings())
          .copyWith(model: typed),
    );
  }

  void _onModelChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  /// 切格式时该不该自动填默认地址：地址为空、或正好等于**另一格式**的默认值。
  /// 用户自己填的代理地址一个字都不动。
  static String _baseAfterFormatSwitch(AiSettings s, AiApiFormat next) {
    final current = s.baseUrl.trim();
    final nextDefault = AiSettings.defaultBaseFor(next);
    // **没有默认地址的档（New API）一个字都不动** —— 它能吃的是用户自己的
    // 网关地址，清空只会把刚填好的东西抹掉。这一条必须排在下面那条之前。
    if (nextDefault.isEmpty) return s.baseUrl;
    final previousDefault = AiSettings.defaultBaseFor(s.apiFormat);
    if (current.isEmpty || current == previousDefault) {
      return nextDefault;
    }
    return s.baseUrl;
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _modelFocus.removeListener(_onModelFocusChanged);
    _modelFocus.dispose();
    _model.dispose();
    _keyFocus.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(aiSettingsProvider);
    final settings = async.value ?? const AiSettings();
    // 首读落地 / 别处改了模型名 → 铺进输入框。**放在 build 里**（而不是
    // `ref.listen`）是因为它必须与「这一帧用的 `settings`」是同一份：铺的
    // 那一刻就得按最新值判按钮可用性，晚一帧会出现「框里明明有名字、按钮
    // 还是灰的」这种一闪。
    _syncModelField(settings);
    // 三处**草稿**：模型栏的控制器 / `_urlDraft` / `_key` 里正在敲的内容要先算数，
    // 否则「敲完直接点按钮」点不动（`settings` 里的值要等提交/失焦才更新）。
    // 按钮只认草稿，落盘前会把草稿落一次盘（见 `_prepare`）。
    final effectiveModel = _modelDraft;
    // 按钮的可用性要跟着打字变，所以地址这半用**草稿**：敲完地址直接点「拉取」
    // 是最自然的动作，等提交/失焦才认的话就得点两次。红字（见下面 `_TextTile`
    // 的 errorText）判的是同一个草稿 —— 两处用的是同一个判据。
    final effectiveUrl = _urlDraft ?? settings.baseUrl;
    final urlValid = _urlLooksValid(effectiveUrl);
    final keyPresent = _keyPresent(settings);
    // 三样齐没齐：**地址 + 格式 + Key**。格式永远有值（下拉框，不是输入框），
    // 所以「三样」在界面上是两条输入 + 一个下拉。
    final fieldsReady = urlValid && keyPresent;

    return ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          // 隐私声明摆**最上面**，不藏在底部：spec §4.4 要求它出现在这一页，
          // 而放在滚动条的尽头等于「没出现」。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.privacy_tip_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.aiPrivacyNotice,
                    key: const ValueKey('ai-privacy'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          if (!settings.isUsable)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                l10n.aiUnavailable,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (ref.watch(aiSettingsStoreProvider).isKeychainDegraded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                l10n.aiKeyDegraded,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),

          // 「服务商」这一段就是「三样齐了才能拉取/测试」在版面上的落点：
          // 地址 → 格式 → Key，顺序即填的顺序，缺哪样下面那行小字就说哪样。
          const Divider(),
          SettingsSectionHeader(title: l10n.aiProviderSection),
          _TextTile(
            fieldKey: const ValueKey('ai-base-url'),
            label: l10n.aiBaseUrlLabel,
            // hint 跟格式走：三种协议对「带不带 /v1」的要求各不相同（见
            // `_FormatTile._hint`），地址栏自己写死一个例子会与上面那档打架。
            hint: _FormatTile._hint(l10n, settings.apiFormat),
            initial: settings.baseUrl,
            // 只判协议前缀（spec §6.3），且跟着打字实时报 —— 用户填完地址栏
            // 那一刻就该知道对不对，而不是等按了按钮。下面按钮的可用性判的是
            // 同一个草稿。
            errorText: urlValid ? null : l10n.aiBaseUrlInvalid,
            onChanged: (value) => setState(() => _urlDraft = value),
            onSubmitted: (value) =>
                _save(settings.copyWith(baseUrl: value.trim())),
          ),
          _FormatTile(
            settings: settings,
            onChanged: (next) => _save(
              settings.copyWith(
                apiFormat: next,
                baseUrl: _baseAfterFormatSwitch(settings, next),
              ),
            ),
          ),
          SettingsSectionHeader(title: l10n.aiKeySection),
          ListTile(
            dense: true,
            title: Text(
              settings.hasApiKey ? l10n.aiKeyStored : l10n.aiKeyNotStored,
            ),
            trailing: settings.hasApiKey
                ? TextButton(
                    key: const ValueKey('ai-key-clear'),
                    onPressed: _clearKey,
                    child: Text(l10n.aiKeyClear),
                  )
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey('ai-key'),
                    controller: _key,
                    focusNode: _keyFocus,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    // 校验放在输入时：贴 Key 最常见的错就是尾部那个换行，
                    // 让用户在**贴的那一刻**看到问题，而不是点了保存之后。
                    onChanged: (value) => setState(
                      () => _keyError = AiProvider.validateApiKey(value),
                    ),
                    decoration: InputDecoration(
                      labelText: l10n.aiKeyLabel,
                      // 存过 Key 就在空框里显示一串掩码：让「这儿已经有东西了」
                      // 一眼看得见。**它是 hint，不是值** —— 从来没进过
                      // `_key` 控制器，所以不会被 `_saveKey` 当成 Key 存回去；
                      // 用户一打字它就自然消失。
                      hintText: settings.hasApiKey ? keyMask : null,
                      border: const OutlineInputBorder(),
                      errorText: _keyErrorText(l10n),
                      // 明晃晃一颗「粘贴」：不指望系统的 Cmd/Ctrl+V 在这台设备上
                      // 一定送来文本（见 `_pasteKey` 的注释），把它做成**这颗框
                      // 自己的**一条路径，就跟菜单/快捷键走的是哪套无关了。
                      suffixIcon: IconButton(
                        key: const ValueKey('ai-key-paste'),
                        icon: const Icon(Icons.content_paste_go),
                        tooltip: l10n.aiKeyPaste,
                        visualDensity: VisualDensity.compact,
                        onPressed: _pasteKey,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('ai-key-save'),
                  onPressed: _saveKey,
                  child: Text(l10n.aiKeySave),
                ),
              ],
            ),
          ),

          const Divider(),
          SettingsSectionHeader(title: l10n.aiModelSection),
          // 一行三样：**可编辑的模型下拉**（左，占满余宽）+ 嵌在它右沿的
          // 「拉取」+ 同行的「测试连接」。拉取按钮长在下拉里，是因为它俩
          // 是一件事的两半：拉回来的名字直接落进这个下拉。
          _ModelRow(
            controller: _model,
            focus: _modelFocus,
            menu: _modelMenu,
            models: _models,
            hint: l10n.aiModelHint,
            fetchLabel: l10n.aiModelsFetch,
            testLabel: l10n.aiTestConnection,
            fieldsReady: fieldsReady,
            modelPresent: effectiveModel.trim().isNotEmpty,
            fetching: _fetchingModels,
            testing: _testing,
            onSelected: (value) =>
                _save(settings.copyWith(model: value.trim())),
            onFetch: () => _fetchModels(settings, url: effectiveUrl),
            onTest: () => _testConnection(
              settings,
              url: effectiveUrl,
              model: effectiveModel,
            ),
          ),
          _ProviderActions(
            keyPresent: keyPresent,
            urlValid: urlValid,
            modelPresent: effectiveModel.trim().isNotEmpty,
            modelsNotice: _modelsNotice,
            testError: _testError,
            testChars: _testChars,
          ),

          const Divider(),
          SettingsSectionHeader(title: l10n.aiFeaturesSection),
          SwitchListTile(
            key: const ValueKey('ai-inline'),
            value: settings.inlineContinuationEnabled,
            title: Text(l10n.aiInlineContinuation),
            subtitle: Text(l10n.aiInlineContinuationHint),
            onChanged: (value) =>
                _save(settings.copyWith(inlineContinuationEnabled: value)),
          ),
          SwitchListTile(
            key: const ValueKey('ai-preflight'),
            value: settings.preflightEnabled,
            title: Text(l10n.aiPreflight),
            subtitle: Text(l10n.aiPreflightHint),
            onChanged: (value) =>
                _save(settings.copyWith(preflightEnabled: value)),
          ),
          SwitchListTile(
            key: const ValueKey('ai-subject'),
            value: settings.subjectSuggestEnabled,
            title: Text(l10n.aiSubjectSuggest),
            subtitle: Text(l10n.aiSubjectSuggestHint),
            onChanged: (value) =>
                _save(settings.copyWith(subjectSuggestEnabled: value)),
          ),
          SwitchListTile(
            key: const ValueKey('ai-polish'),
            value: settings.polishEnabled,
            title: Text(l10n.aiPolish),
            subtitle: Text(l10n.aiPolishHint),
            onChanged: (value) => _save(settings.copyWith(polishEnabled: value)),
          ),
          SwitchListTile(
            key: const ValueKey('ai-suggest'),
            value: settings.mailSuggestEnabled,
            title: Text(l10n.aiSuggest),
            subtitle: Text(l10n.aiSuggestHint),
            onChanged: (value) =>
                _save(settings.copyWith(mailSuggestEnabled: value)),
          ),

          const Divider(),
          SettingsSectionHeader(title: l10n.aiBudgetSection),
          ListTile(
            dense: true,
            title: Text(l10n.aiDailyLimit),
            subtitle: Text(l10n.aiDailyLimitHint),
            trailing: Text(
              l10n.aiUsedToday(ref.watch(aiServiceProvider).usedToday),
            ),
          ),
          // 上限是**软**的：`AiUsageCounter.canCall` 只用来提示，
          // 真正的拦与不拦在 `AiService.overDailyLimit`（Task D8）。
          Slider(
            value: settings.dailyCallLimit.clamp(0, 1000).toDouble(),
            max: 1000,
            divisions: 20,
            label: '${settings.dailyCallLimit}',
            onChanged: (value) =>
                _save(settings.copyWith(dailyCallLimit: value.round())),
          ),
        ],
    );
  }

  String? _keyErrorText(AppLocalizations l10n) {
    switch (_keyError) {
      case 'emptyKey':
        return l10n.aiKeyEmpty;
      case 'whitespaceInKey':
        return l10n.aiKeyWhitespace;
      default:
        return null;
    }
  }

  /// 「粘贴」那颗按钮落地的动作。
  ///
  /// 为什么不只靠系统的粘贴：这台设备上实测「按了没反应」，而同一次构建里
  /// 别处的输入框是好的，说明问题出在这颗框自己身上而不是剪贴板本身。与其继续
  /// 猜是谁把那次事件吃了（桌面端快捷键要穿过原生菜单的 `paste:` 选择器才能
  /// 变成文本，中间任何一环不认它，Dart 这边什么都收不到），不如把它做成
  /// **一条不依赖那条链路**的路径：主动读剪贴板，主动写进这颗框。
  Future<void> _pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.aiKeyPasteEmpty)));
      return;
    }
    // Key 从别的工具里复制出来时**常常带着换行**（尾部那一两个换行是最常见的），
    // 而校验里那条「含空白字符」一旦被触发，用户看到的是「检查一下粘贴」——
    // 他要的这次粘贴就白做了。这里替他收掉**首尾**空白（只收首尾：中间的空格
    // 是另一类错，得留着报出来）。
    _setKeyDraft(text.trim());
    _keyFocus.requestFocus();
  }

  /// 往 Key 输入框里落一段内容。
  ///
  /// 写的是 `TextEditingController`（这颗框的真源），不是去够 `EditableTextState`
  /// 的 `updateEditingValue` —— 后者要求连接已经建起来，多一层没必要的耦合。
  /// 写控制器会走一遍 `onChanged`（`EditableText` 把回调挂在这份控制器上），
  /// 所以校验其实已经跑过了；这次 `setState` 只是让「框里的文本」与「`_keyError`」
  /// 在任何路径下都同步更新，读代码时不必去推「这一次到底会不会触发 `onChanged`」。
  /// 光标顺手收到末尾，用户接着就能改尾巴上的字符。
  void _setKeyDraft(String text) {
    _key.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _keyError = AiProvider.validateApiKey(text));
  }

  /// 保存非敏感那半。**不碰 Key** —— 这是 `AiSettingsController.save` 的
  /// 契约（Task D9：它会把 `hasApiKey` 从旧状态带过来，所以这里传进去的对象
  /// 不知道 Key 也没关系）。
  Future<void> _save(AiSettings next) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(aiSettingsProvider.notifier).save(next);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
  }

  Future<void> _saveKey() async {
    final raw = _key.text;
    final error = AiProvider.validateApiKey(raw);
    if (error != null) {
      setState(() => _keyError = error);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    await ref.read(aiSettingsProvider.notifier).setApiKey(raw);
    if (!mounted) return;
    // **存完立刻把明文从内存里抹掉**：它已经进了钥匙串，再留在这个
    // `TextEditingController` 里只是白白多一份副本。
    _key.clear();
    setState(() => _keyError = null);
    messenger.showSnackBar(SnackBar(content: Text(l10n.aiKeySaved)));
  }

  Future<void> _clearKey() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    // 没有 `clearApiKey()` 这个方法：空串就是删除
    // （`AiApiKeyStore.write` 的语义，Task D7）。
    await ref.read(aiSettingsProvider.notifier).setApiKey('');
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(l10n.aiKeyCleared)));
  }

  /// 发货前把**还没落盘的草稿**落一次。
  ///
  /// 两个按钮的可用性认草稿（见 `_keyPresent` / `effectiveUrl`），所以点下去
  /// 就得让草稿**变成真的** —— 否则按钮亮着而 `AiService` 读到的还是旧设置，
  /// 用户看到的是「按了没反应 / 报的还是上一个地址」。两件都幂等：地址相同就
  /// 不写、Key 还是同一串就只是又进了一次钥匙串。
  ///
  /// 地址这半走 [_save]（整份覆盖），所以**调用方自己要先存的东西必须先存**：
  /// 反过来（先 `_prepare` 再拿旧的 `settings` 去 `copyWith`）会把这里刚落盘的
  /// 地址成片抹回去。模型名那半由 `_ModelRow.onSelected` / 失焦那条路自己落盘。
  ///
  /// 存 Key 走 [_saveKey] 那条既有路径（校验 + 写钥匙串 + 清明文 + 校准回读），
  /// 于是「点了拉取就等于顺手点了保存」，不会多出一套语义。
  Future<void> _prepare(AiSettings next, {required String url}) async {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isNotEmpty && trimmedUrl != next.baseUrl.trim()) {
      await _save(next.copyWith(baseUrl: trimmedUrl));
      if (!mounted) return;
    }
    // Key 这半**不受地址那半的影响**：地址没变时也要存 Key，否则「只填了 Key
    // 就点拉取」会发出一个没有 Key 的请求（`AiService` 只会回「还没配置 AI」）。
    final typed = _key.text.trim();
    if (typed.isNotEmpty && AiProvider.validateApiKey(typed) == null) {
      await _saveKey();
    }
  }

  /// 拉模型列表 → **填进下拉并弹开**；拉不到只在按钮下方留一行提示。
  ///
  /// **失败永远不拦手输**：有些代理根本不实现 `/models`，而它照样能生成。
  /// 这也是下拉必须是**可编辑**的那一半理由 —— 拉回来的是候选，不是全部。
  ///
  /// [url] 是地址栏**眼下的内容**（可能还没失焦、还没落盘）—— 与 [_testConnection]
  /// 同一个理由，先 `_prepare` 再发请求。
  Future<void> _fetchModels(AiSettings settings, {required String url}) async {
    setState(() {
      _fetchingModels = true;
      _modelsNotice = null;
      _testChars = null;
      _testError = null;
    });
    final l10n = AppLocalizations.of(context);
    await _prepare(settings, url: url);
    if (!mounted) return;
    final result = await ref.read(aiServiceProvider).listModels();
    if (!mounted) return;
    switch (result) {
      case AiModelsFailed(:final message):
        setState(() {
          _fetchingModels = false;
          _modelsNotice = l10n.aiModelsFailed(message);
        });
      case AiModelsOk(:final models) when models.isEmpty:
        setState(() {
          _fetchingModels = false;
          _modelsNotice = l10n.aiModelsEmpty;
        });
      case AiModelsOk(:final models):
        setState(() {
          _fetchingModels = false;
          _models = models;
        });
        // 弹开菜单让用户直接挑。先前那个底部选择器（带自己的搜索框）没有了：
        // 下拉本身就能过滤，再叠一层是同一个功能做两遍。
        _modelMenu.open();
    }
  }

  /// 试一次真实生成（不是拉列表）。结果就地显示，成功与失败各一行。
  ///
  /// [model] / [url] 都是栏里**眼下的内容**（可能还没失焦、还没落盘）：用户敲完
  /// 直接点按钮时，先用它把草稿落一次再测 —— 否则测的是上一份设置，而
  /// `_ProviderActions` 的可用性判定与这里用的必须是同一个值。
  Future<void> _testConnection(
    AiSettings settings, {
    required String url,
    required String model,
  }) async {
    setState(() {
      _testing = true;
      _testChars = null;
      _testError = null;
      _modelsNotice = null;
    });
    final trimmed = model.trim();
    // `next` 是**带上模型草稿的那一份**，一路传给 `_prepare`（见它那里的长注释）。
    var next = settings;
    if (trimmed.isNotEmpty && trimmed != settings.model.trim()) {
      next = settings.copyWith(model: trimmed);
      await _save(next);
      if (!mounted) return;
    }
    await _prepare(next, url: url);
    if (!mounted) return;
    final result = await ref.read(aiServiceProvider).testConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      switch (result) {
        case AiTestOk(:final chars):
          _testChars = chars;
        case AiTestFailed(:final message):
          _testError = message;
      }
    });
  }
}

/// API 格式下拉。厂商下拉的替代 —— 它选的不是「哪家」，而是「哪种协议」。
class _FormatTile extends StatelessWidget {
  const _FormatTile({required this.settings, required this.onChanged});

  final AiSettings settings;
  final ValueChanged<AiApiFormat> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(AppLocalizations.of(context).aiApiFormatLabel),
    trailing: DropdownButton<AiApiFormat>(
      key: const ValueKey('ai-api-format'),
      value: settings.apiFormat,
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      items: <DropdownMenuItem<AiApiFormat>>[
        for (final f in AiApiFormat.values)
          DropdownMenuItem<AiApiFormat>(
            value: f,
            // 格式名**不本地化成别的词**：它们是协议名（OpenAI 兼容 /
            // Anthropic），翻成「人类学」只会让人找不到。
            child: Text(_label(AppLocalizations.of(context), f)),
          ),
      ],
    ),
  );

  static String _label(AppLocalizations l10n, AiApiFormat f) => switch (f) {
    AiApiFormat.openai => l10n.aiApiFormatOpenai,
    AiApiFormat.anthropic => l10n.aiApiFormatAnthropic,
    // New API 也是协议名（它是那一系网关自己的叫法），不本地化。
    AiApiFormat.newapi => l10n.aiApiFormatNewapi,
  };

  static String _hint(AppLocalizations l10n, AiApiFormat f) => switch (f) {
    AiApiFormat.openai => l10n.aiBaseUrlHint,
    AiApiFormat.anthropic => l10n.aiBaseUrlHintAnthropic,
    // 这一档的 hint 特意**不写具体地址**：网关是自建的，写一个别人的主机名
    // 只会被照抄。写的是「该填什么形态」。
    AiApiFormat.newapi => l10n.aiBaseUrlHintNewapi,
  };
}

/// 模型那一行：**可编辑的下拉** + 嵌在下拉右沿的「拉取」+ 同行的「测试连接」。
///
/// 为什么是下拉而不是纯输入框（用户要求的）：拉回来的模型名本来就该**挑**，
/// 而不是从一长串里抄一个。为什么还必须**可编辑**：有些代理根本不实现
/// `/models`（拉取会失败）、有些名字不在列表里 —— 只能手输。两条路都在
/// 同一个输入框上，所以下拉是 `DropdownMenu` 而不是 `DropdownButton`。
///
/// 「拉取」长在下拉的 `suffixIcon` 里、跟下拉箭头并排：它俩是一件事的两半
/// （点拉取 → 名字填进这个框）。
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.controller,
    required this.focus,
    required this.menu,
    required this.models,
    required this.hint,
    required this.fetchLabel,
    required this.testLabel,
    required this.fieldsReady,
    required this.modelPresent,
    required this.fetching,
    required this.testing,
    required this.onSelected,
    required this.onFetch,
    required this.onTest,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final MenuController menu;

  /// 上一次拉回来的候选。空列表时下拉里就只有手输那一个值 ——
  /// 不影响用（`DropdownMenu` 允许空 entries）。
  final List<String> models;

  final String hint;
  final String fetchLabel;
  final String testLabel;

  /// 地址合法 **且** Key 填了（**含还没落盘的草稿**）。拉取的门槛。
  final bool fieldsReady;

  final bool modelPresent;
  final bool fetching;
  final bool testing;

  /// 从下拉里挑中一条。落盘在这里做（挑中就是「定下来」），而不是等失焦。
  final ValueChanged<String> onSelected;
  final VoidCallback onFetch;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final canFetch = fieldsReady && !fetching && !testing;
    // 「测试连接」比拉取多一条模型非空（少了名字没得测）。
    final canTest = canFetch && modelPresent;

    // 存过的名字可能不在这次拉回来的列表里（换了端点、或者本来就是手输的）——
    // 补进去，否则下拉会把它显示成「没选中」。
    final current = controller.text.trim();
    final entries = <String>[
      ...models,
      if (current.isNotEmpty && !models.contains(current)) current,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: DropdownMenu<String>(
              key: const ValueKey('ai-model'),
              controller: controller,
              focusNode: focus,
              menuController: menu,
              // 允许手输（默认在桌面平台就是，这里显式钉住：手机平台默认
              // 是不可编辑的按钮形态，而手输是这一栏的必需能力）。
              requestFocusOnTap: true,
              // 菜单里跟着打字过滤 —— 拉回来的可能有几百条。
              enableFilter: true,
              // 占满 `Expanded` 给的宽度。不给的话宽度由菜单项里最长的那条
              // 决定，条目一多就撑出屏幕。
              expandedInsets: EdgeInsets.zero,
              onSelected: (value) {
                if (value == null) return;
                // 选中即落盘 —— 「挑一条」就是把它定下来，不用再失焦一次。
                // 输入框由 `DropdownMenu` 自己铺（它会把 `label` 写进控制器）。
                onSelected(value);
              },
              decorationBuilder: (_, controller) => InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton(
                      key: const ValueKey('ai-models-fetch'),
                      onPressed: canFetch ? onFetch : null,
                      child: fetching
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(fetchLabel),
                    ),
                    IconButton(
                      key: const ValueKey('ai-model-toggle'),
                      onPressed: controller.open,
                      icon: const Icon(Icons.arrow_drop_down),
                    ),
                  ],
                ),
              ),
              dropdownMenuEntries: <DropdownMenuEntry<String>>[
                for (final name in entries)
                  DropdownMenuEntry<String>(
                    value: name,
                    label: name,
                    // 条目的 `label` 只能是字符串（选中后它就是输入框里的内容），
                    // 所以 key 挂在 `labelWidget` 上 —— 筛选认的仍是 `label`，
                    // 而测试与无障碍能按 key 找到某一条。这个 widget 只在
                    // 菜单**打开**时存在。
                    labelWidget: Text(
                      name,
                      key: ValueKey('ai-model-option-$name'),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const ValueKey('ai-test-connection'),
            onPressed: canTest ? onTest : null,
            icon: testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bolt_outlined, size: 18),
            label: Text(testLabel),
          ),
        ],
      ),
    );
  }
}

/// 两个按钮下方那几行就地提示：**差什么** / 拉取的结果 / 测试的结果。
///
/// 单拎出来是因为按钮搬进了 [_ModelRow]：这里只剩下「说给用户听的话」。
class _ProviderActions extends StatelessWidget {
  const _ProviderActions({
    required this.keyPresent,
    required this.urlValid,
    required this.modelPresent,
    required this.modelsNotice,
    required this.testError,
    required this.testChars,
  });

  /// Key / 地址 / 模型各自那半 —— 决定「差什么」说哪句。
  final bool keyPresent;
  final bool urlValid;
  final bool modelPresent;

  /// **一整句已经拼好的话** —— 直接显示，不再套前缀。
  final String? modelsNotice;
  final String? testError;
  final int? testChars;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // 差什么就直接说，而不是让用户点下去才发现点不动。先说 Key、再说地址 ——
    // 与上面「服务商」那一段的填写顺序一致（地址 → 格式 → Key 是版面顺序，
    // 而这里按「用户更难自己发现的那个」排：地址栏已经红字写着格式不对了）。
    final String? why;
    if (!keyPresent) {
      why = l10n.aiModelsFetchNeedKey;
    } else if (!urlValid) {
      why = l10n.aiModelsFetchNeedUrl;
    } else if (!modelPresent) {
      // 三样齐了、只差模型：说清楚「测试连接」为什么还灰着。拉取不受影响。
      why = l10n.aiTestNeedModel;
    } else {
      why = null;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (why != null)
            Text(
              why,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (modelsNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                modelsNotice!,
                key: const ValueKey('ai-models-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (testChars != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                // 「返回了 0 个字」读起来像失败 —— 而它是通的，只是这次没吐可见
                // 文本（推理模型把预算花在思考上）。换一句不会让人误会的。
                testChars == 0 ? l10n.aiTestOkNoText : l10n.aiTestOk(testChars!),
                key: const ValueKey('ai-test-ok'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          if (testError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.aiTestFailed(testError!),
                key: const ValueKey('ai-test-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一行文本输入。提交（回车 / 失焦）时才写回 —— 每敲一个字母就存一次
/// 会让 prefs 写入跟着打字节奏跑。
class _TextTile extends StatefulWidget {
  const _TextTile({
    required this.fieldKey,
    required this.label,
    required this.hint,
    required this.initial,
    required this.onSubmitted,
    this.onChanged,
    this.errorText,
  });

  final Key fieldKey;
  final String label;
  final String hint;
  final String initial;
  final ValueChanged<String> onSubmitted;

  /// 每次敲键都回调（**不落盘**）—— 给地址栏做即时校验用。落盘仍然只在
  /// 提交/失焦时发生。
  final ValueChanged<String>? onChanged;

  /// 校验没过时显示在输入框下的红字。
  final String? errorText;

  @override
  State<_TextTile> createState() => _TextTileState();
}

class _TextTileState extends State<_TextTile> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void didUpdateWidget(_TextTile old) {
    super.didUpdateWidget(old);
    // 外面把值改了（比如切格式带出来的默认地址、选择器写回的模型名）→ 跟上去。
    // **只在 `initial` 本身变了的时候才动控制器**：父级因为别的 setState
    // （地址栏每敲一键的即时校验就属于这种）重建时 `initial` 没变，那种重建
    // 绝不能把用户正在敲的字改回去。不一致才写，否则会打断输入法组词。
    if (widget.initial != old.initial && widget.initial != _controller.text) {
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: TextField(
      key: widget.fieldKey,
      controller: _controller,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        border: const OutlineInputBorder(),
        errorText: widget.errorText,
      ),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      onTapOutside: (_) => widget.onSubmitted(_controller.text),
    ),
  );
}

