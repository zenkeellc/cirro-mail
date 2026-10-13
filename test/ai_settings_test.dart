import 'package:flutter_test/flutter_test.dart';
import 'package:mail_app/features/ai/ai_provider.dart';
import 'package:mail_app/features/ai/ai_settings.dart';

void main() {
  group('默认值', () {
    test('全新安装：OpenAI 兼容 + 官方地址 + 空模型', () {
      const s = AiSettings();
      expect(s.apiFormat, AiApiFormat.openai);
      expect(s.baseUrl, AiSettings.openaiDefaultBase);
      expect(s.model, isEmpty, reason: '没有一个模型名能当所有端点的默认值');
      expect(s.isUsable, isFalse, reason: '没 Key 就是不可用');
    });

    test('行内续写默认关（每次停笔都花钱）', () {
      expect(const AiSettings().inlineContinuationEnabled, isFalse);
    });

    test('发送前检查默认开（那条本地规则零成本）', () {
      expect(const AiSettings().preflightEnabled, isTrue);
    });

    test('两个「点一下才花钱」的入口默认都开（起标题与润色）', () {
      // 与行内续写不同：那一个每次停笔都会调用，默认关；这两个都是用户
      // 主动点才发生，默认开才用得上。
      expect(const AiSettings().subjectSuggestEnabled, isTrue);
      expect(const AiSettings().polishEnabled, isTrue);
    });

    test('两个官方地址常量与 AiProvider 那份同源', () {
      expect(AiSettings.openaiDefaultBase, AiProvider.openaiDefaultBase);
      expect(AiSettings.anthropicDefaultBase, AiProvider.anthropicDefaultBase);
    });

    test('New API 没有默认地址 —— 自建网关，给个假地址比不给更糟', () {
      expect(AiSettings.newapiDefaultBase, isEmpty);
      expect(AiProvider.newapiDefaultBase, isEmpty);
    });

    test('AI 建议默认开（这是读邮件那一侧的入口，不是花钱的按钮）', () {
      expect(const AiSettings().mailSuggestEnabled, isTrue);
    });
  });

  group('isUsable', () {
    test('缺 Key → 不可用', () {
      expect(
        const AiSettings(model: 'm', baseUrl: 'https://x').isUsable,
        isFalse,
      );
    });

    test('缺地址 → 不可用（地址现在是所有人都要填的）', () {
      expect(
        const AiSettings(hasApiKey: true, model: 'm', baseUrl: '   ').isUsable,
        isFalse,
      );
    });

    test('缺模型 → 不可用', () {
      expect(
        const AiSettings(hasApiKey: true, baseUrl: 'https://x').isUsable,
        isFalse,
      );
    });

    test('模型只有空白 → 不可用（走的是 trim 分支，不是空默认值）', () {
      expect(
        const AiSettings(hasApiKey: true, model: '   ', baseUrl: 'https://x')
            .isUsable,
        isFalse,
      );
    });

    test('三样齐 → 可用', () {
      expect(
        const AiSettings(hasApiKey: true, model: 'm', baseUrl: 'https://x')
            .isUsable,
        isTrue,
      );
    });

    test('hasEndpoint 不看模型名 —— 差的就是拉取要拿的东西', () {
      const noModel = AiSettings(hasApiKey: true, baseUrl: 'https://x');
      expect(noModel.isUsable, isFalse, reason: '生成类能力要模型名');
      expect(noModel.hasEndpoint, isTrue, reason: '但拉模型列表不该被它卡住');
    });

    test('hasEndpoint 在缺地址或缺 Key 时仍然是 false', () {
      expect(
        const AiSettings(hasApiKey: true, baseUrl: '  ').hasEndpoint,
        isFalse,
      );
      expect(const AiSettings(baseUrl: 'https://x').hasEndpoint, isFalse);
    });
  });

  group('copyWith 与相等性', () {
    test('换格式与地址', () {
      const s = AiSettings();
      expect(s.copyWith(apiFormat: AiApiFormat.anthropic).apiFormat,
          AiApiFormat.anthropic);
      expect(s.copyWith(baseUrl: 'https://a').baseUrl, 'https://a');
    });

    test('copyWith 真的能改 mailSuggestEnabled（与 == 是两件事）', () {
      // 上面那一组钉的是「它参与 ==」，这一条钉的是「copyWith 认它」——
      // 两个独立失效：字段漏进 `==`，界面关掉开关不重建；漏进 `copyWith`，
      // 开关点下去状态根本没变。各测一半才拦得住。
      expect(const AiSettings().mailSuggestEnabled, isTrue);
      expect(
        const AiSettings().copyWith(mailSuggestEnabled: false).mailSuggestEnabled,
        isFalse,
      );
    });

    test('值相同就相等（自反性）—— 它是 Riverpod 状态，判定靠 ==', () {
      expect(const AiSettings(hasApiKey: true), const AiSettings(hasApiKey: true));
      expect(
        const AiSettings(hasApiKey: true).hashCode,
        const AiSettings(hasApiKey: true).hashCode,
      );
    });

    test('每个字段都参与 == —— 漏一个就会「两个不同状态比成相等」，界面不重建', () {
      expect(AiSettings(apiFormat: AiApiFormat.anthropic) == const AiSettings(),
          isFalse);
      expect(AiSettings(model: 'm') == const AiSettings(), isFalse);
      expect(AiSettings(baseUrl: 'https://x') == const AiSettings(), isFalse);
      expect(AiSettings(hasApiKey: true) == const AiSettings(), isFalse);
      expect(
        AiSettings(inlineContinuationEnabled: true) == const AiSettings(),
        isFalse,
      );
      expect(AiSettings(preflightEnabled: false) == const AiSettings(), isFalse);
      expect(
        AiSettings(subjectSuggestEnabled: false) == const AiSettings(),
        isFalse,
      );
      expect(AiSettings(polishEnabled: false) == const AiSettings(), isFalse);
      expect(AiSettings(dailyCallLimit: 7) == const AiSettings(), isFalse);
      expect(
        const AiSettings() == const AiSettings(mailSuggestEnabled: false),
        isFalse,
        reason: 'mailSuggestEnabled 没参与 == —— 关掉开关界面不会变',
      );
    });

    test('toString 里没有 Key（这个对象本来就不带 Key，把约定钉在测试里）', () {
      const s = AiSettings(hasApiKey: true, model: 'm');
      expect(s.toString(), contains('hasKey=true'));
      expect(s.toString(), isNot(contains('sk-')));
    });
  });

  group('toProvider', () {
    test('三样字段原样带过去', () {
      const s = AiSettings(
        apiFormat: AiApiFormat.anthropic,
        model: 'claude-x',
        baseUrl: 'https://api.anthropic.com',
      );
      final p = s.toProvider();
      expect(p.format, AiApiFormat.anthropic);
      expect(p.model, 'claude-x');
      expect(p.baseUrl, 'https://api.anthropic.com');
    });

    test('两端空白被 trim —— model 一路写进请求 JSON，不能在线上带空格', () {
      const s = AiSettings(model: ' m ', baseUrl: ' https://x ');
      final p = s.toProvider();
      expect(p.model, 'm');
      expect(p.baseUrl, 'https://x');
    });
  });

  group('defaultBaseFor', () {
    test('两档各回自己的官方地址', () {
      expect(AiSettings.defaultBaseFor(AiApiFormat.openai),
          AiSettings.openaiDefaultBase);
      expect(AiSettings.defaultBaseFor(AiApiFormat.anthropic),
          AiSettings.anthropicDefaultBase);
    });

    test('New API 回空串（「这一档没有默认地址」的表示）', () {
      expect(AiSettings.defaultBaseFor(AiApiFormat.newapi), isEmpty);
    });
  });
}
