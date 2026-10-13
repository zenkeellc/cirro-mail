import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/router.dart';

/// 四个纯本机页面的地址。
///
/// 这里钉住的是「它们**不再是设置页的子路由**」—— 地址少一段 `/settings`
/// 意味着它们在导航上有自己的位置，而不是设置页里的一个选项。
/// 这一条在界面上看不出来（都是全屏页面），但**返回键的落点**按它算：
/// 一个 `/settings/outbox` 的深链会让系统返回键把人送回设置页，
/// 而用户根本没去过那里。
void main() {
  test('发件箱 / 草稿箱 / 附件缓存都在壳的根上', () {
    expect(Routes.outbox, '/outbox');
    expect(Routes.drafts, '/drafts');
    expect(Routes.attachmentCache, '/attachment-cache');
  });

  /// 这三条地址**已经不再是一条页面**，但常量必须留着。
  ///
  /// `/settings/ai`、`/settings/push`、`/settings/diagnostics` 曾经是三个
  /// 独立整页，现在都并进 `/settings` 自己的分类里（宽屏在右栏内嵌、窄屏
  /// 是一页）。地址留着是因为**深链不该 404** —— 它们可能出现在用户的浏览
  /// 历史、通知、或某份旧文档里；`router.dart` 里那三条此刻都是
  /// `redirect: (…) => Routes.settings`。
  ///
  /// 「它们确实是重定向」这件事钉在 `settings_layout_test.dart` 里（那条会
  /// 真的把路由表翻出来看），这里只钉常量本身没被顺手删掉 —— 那一步在界面上
  /// 完全看不出来，只有某个存过旧地址的人会撞上 404。
  test('设置页那几个真正的子路由还在', () {
    expect(Routes.diagnostics, '/settings/diagnostics');
    expect(Routes.pushSettings, '/settings/push');
    expect(Routes.addInstance, '/settings/add-instance');
    expect(Routes.aiSettings, '/settings/ai');
    // 只有「添加实例」还是一张真的表单页（`ServerSetupScreen`），
    // 另外三条现在只是兼容用的重定向。
    for (final legacy in <String>[
      Routes.diagnostics,
      Routes.pushSettings,
      Routes.aiSettings,
    ]) {
      expect(
        legacy.startsWith('${Routes.settings}/'),
        isTrue,
        reason: '$legacy 在设置这一支下面 —— 外壳靠路径段判它，前缀错一格'
            '就会让写邮件 FAB 出现在设置页上',
      );
    }
  });

  /// 推送配置指引是设置页的**下一层**（`/settings/push/guide`），不是
  /// 与它平级的一条。
  ///
  /// 它现在只是一个**重定向**（指引已经并进 `/settings/push` 自己的七页
  /// 向导里，见 `router.dart` 那条 `redirect`），但地址仍然留在
  /// `/settings/push` 这一支里 —— 这一条钉的就是「它不会变成一条平级的
  /// 独立地址」：真要是变成 `/settings/guide`，那个 reflect 到旧深链的人
  /// 会落到设置页首页，而他本来要看的是推送那一块。
  test('推送配置指引挂在 /settings/push 下面', () {
    expect(Routes.pushSetupGuide, '/settings/push/guide');
    expect(Routes.pushSetupGuide, startsWith('${Routes.pushSettings}/'),
        reason: '它必须在推送设置页那一支里');
  });

  test('发件箱里一条的预览有独立的地址（窄屏点开一整页）', () {
    expect(Routes.outboxDetailOf(7), '/outbox/7');
  });

  /// 宽屏下「选中左栏某一条」是**同一个地址 + 一个查询参数**，
  /// 不是一条新路由。
  ///
  /// 这一条钉的是那个会把订阅翻倍的坑：压成路径（`/outbox/7`）时，
  /// go_router 的 `pageKey` 会变，于是 Navigator 在同一个分支上叠一张新页
  /// —— 底下的 `OutboxScreen` 还活着（`maintainState`），两个漂移订阅同时
  /// 开着。查询参数不进 `pageKey`，那一页是原地更新。
  test('宽屏的选中态是 /outbox?sel=<id>，与窄屏那条路径不是同一个地址', () {
    expect(Routes.outboxWith(7), '/outbox?sel=7');
    expect(Routes.outboxWith(7), isNot(Routes.outboxDetailOf(7)));
    // 没选中时不该冒出一个空的 `?sel=`。
    expect(Routes.outboxWith(0), isNot(contains('sel')));
  });

  /// 这三条与 [Routes.mail] 是**互不包含**的路径。
  ///
  /// 看着像废话，但它挡的是一个具体的坑：`/outbox` 若写成 `/out`，
  /// 就会有人把「前缀匹配」当成「同一支」（`/mail/<id>` 那一支的
  /// `location.startsWith(Routes.mail)` 就是这么判的）。这条测试
  /// 把三个地址与 `/mail` 的关系钉死，改错了名字会立刻红。
  test('三个地址都不在邮件分支的前缀里', () {
    for (final path in <String>[
      Routes.outbox,
      Routes.drafts,
      Routes.attachmentCache,
    ]) {
      expect(path.startsWith(Routes.mail), isFalse, reason: path);
      expect(path.startsWith(Routes.settings), isFalse, reason: path);
    }
  });
}
