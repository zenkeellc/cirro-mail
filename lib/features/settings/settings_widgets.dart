/// 设置页各分类里共用的视觉积木 —— 定义在 `cirro_mail_ext` 里。
///
/// 为什么住在公开的扩展包里而不是这个 App：商业包（账号 / 订阅那一栏）
/// **不能** import 核心 App，但两边设置页要长得一模一样，所以积木必须放在
/// 两边都 import 得到的地方。这里只做一次 re-export，历史 import 路径
/// （`../settings_widgets.dart`）与所有调用点都不用改。
///
/// 一套积木的分工见 `packages/cirro_mail_ext/lib/src/settings_widgets.dart`
/// 的库文档：`SettingsGroup`（分组卡片，行间自动分隔）→ `SettingsTile`
/// （组内一行）→ `SettingsHint`（小字说明）/ `SettingsNote`（整块提示）/
/// `SettingsEmptyState`（空态）/ `SettingsPage`（分类正文外壳，宽屏限宽）。
library;

export 'package:cirro_mail_ext/cirro_mail_ext.dart'
    show
        SettingsEmptyState,
        SettingsGroup,
        SettingsHint,
        SettingsNote,
        SettingsPage,
        SettingsSectionHeader,
        SettingsTile;
