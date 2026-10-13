import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/core/storage/prefs_store.dart';
import 'package:mail_app/features/compose/writing_snippets.dart';
import 'package:mail_app/providers/core_providers.dart';
import 'package:mail_app/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 这一组钉的是**写入路径**：签名与常用语必须由 `WritingSnippetsController`
/// 的 `setSignature` / `setPhrases` 写，且两者各改各的、不互相踩。
///
/// 从前设置页绕过 notifier 直接 `store.setSignature` + `ref.invalidate`，
/// 于是那两个方法一个调用点都没有 —— 那时这组用例依然能绿（它测的是 notifier
/// 本身，不是设置页调没调它），但它把「notifier 是唯一写入口」这个契约钉住：
/// 谁再把写入挪回 store，设置页读到的 provider 就不会跟着变。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 把 `prefsStoreProvider` 换成假 prefs 的容器（抄 `ai_providers_test.dart`）。
  Future<ProviderContainer> container() async {
    final c = ProviderContainer.test(
      overrides: [
        prefsStoreProvider.overrideWithValue(
          PrefsStore(await SharedPreferences.getInstance()),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('setSignature 只换签名：同一邮箱的常用语原样，别的邮箱一概不动', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final c = await container();

    // 两个邮箱各有一组常用语（直接写 store，模拟「用户早先配过」）。
    await c.read(prefsStoreProvider).setPhrases('a@b.com', const <WritingSnippet>[
      WritingSnippet(id: '1', name: '约时间', text: '方便的话…'),
    ]);
    await c.read(prefsStoreProvider).setPhrases('c@d.com', const <WritingSnippet>[
      WritingSnippet(id: '9', name: '别的', text: '别的正文'),
    ]);

    await c
        .read(writingSnippetsProvider('a@b.com').notifier)
        .setSignature('新签名');

    final a = c.read(writingSnippetsProvider('a@b.com'));
    // 判据：读 provider 能看到新签名 —— 若 `setSignature` 只写了 store 而没
    // 更新 state（比如回退成「store + invalidate」那套），设置页读到的仍是旧值。
    expect(a.signature, '新签名');
    // 若 `setSignature` 重拼 state 时把 phrases 也动了（整块重置 / 拿签名当常用语），
    // 这里就红。
    expect(a.phrases.map((s) => s.id), <String>['1'],
        reason: 'setSignature 不该动到同一邮箱的常用语');

    // 钉「写到对的那个 key」：email 若传错（恒写空串 / 恒写第一个地址），
    // c@d.com 会被捎带改动，或 a@b.com 根本读不到 —— 这条就红。
    final d = c.read(writingSnippetsProvider('c@d.com'));
    expect(d.signature, isEmpty, reason: '别的邮箱的签名不该被这次写入捎带');
    expect(d.phrases.single.id, '9', reason: '别的邮箱的常用语不该被这次写入捎带');
  });

  test('setPhrases 只换常用语：签名原样', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final c = await container();
    await c.read(prefsStoreProvider).setSignature('a@b.com', '张三\n公司');

    await c.read(writingSnippetsProvider('a@b.com').notifier).setPhrases(
      const <WritingSnippet>[
        WritingSnippet(id: '2', name: '自我介绍', text: '我是…'),
      ],
    );

    final a = c.read(writingSnippetsProvider('a@b.com'));
    expect(a.phrases.single.id, '2');
    // 反向的那条：`setPhrases` 若整块重置、丢了签名，这里红。
    expect(a.signature, '张三\n公司', reason: 'setPhrases 不该动到签名');
  });
}
