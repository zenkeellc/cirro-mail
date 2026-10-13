# 对 `riverpod` 的补丁

上游版本：`riverpod 3.4.3`（`flutter_riverpod 3.4.3` 同日）。
vendor 的是 `riverpod` 这一个包 —— `flutter_riverpod` 不用动（见 `README.md`：
它 3.4.3 对 `riverpod` 是精确约束 `riverpod: 3.4.3`，版本号对得上，覆盖会照样生效）。

**只有一处补丁**，在源码里用 `BEGIN PATCH(cloud-mail)` / `END PATCH(cloud-mail)`
圈出来了，改回来时直接搜这两个标记。

| 文件 | 位置 | 内容 | 上游出处 |
| --- | --- | --- | --- |
| `lib/src/core/provider_subscription.dart` | `ProviderSubscriptionImpl.resume()` | 把 `flush()` 从「恢复订阅之后」挪到「之前」 | `riverpod` 主分支 PR #4884（issue #4882，尚未合并进任何发行版） |

3.4.3 里另外两处相关的修复（`flush()` 的 `_isFlushing` 重入标记、`invalidateSelf()`
排队前判 `!_isFlushing && isActive`）**已经在上游版本里了**，所以这一份不再需要那两处。

## 症状

真机上（macOS 桌面端、窄屏切到宽屏再切回来）出现：

```
setState() or markNeedsBuild() called during build.
This UncontrolledProviderScope widget cannot be marked as needing to build ...
The widget which was currently being built when the offending call was made was:
  _UncontrolledProviderScope
#3  _UncontrolledProviderScopeState.scheduleRefresh
#8  ProviderElement.invalidateSelf
#10 Ref.watch.<anonymous closure>
#21 ProviderSubscriptionImpl.resume
#22 ConsumerStatefulElement._updateTickerMode
#25 _TickerModeState._updateEffectiveMode
```

## 根因

一句话：**在 Flutter 的 build 阶段里，某个 provider 的 `invalidateSelf` 排了一次
刷新，而这次刷新要 `setState` 的 `UncontrolledProviderScope` 就在树根上 ——
它不是当前 build 目标的祖先，于是 Flutter 直接断言失败。**

触发链（`go_router` 的 `StatefulShellRoute.indexedStack` 用
`TickerMode(enabled: isActive)` 包住每个分支，切分支时 enabled 翻转）：

1. 分支不可见 → `TickerMode` 变 false → `ConsumerStatefulElement._updateTickerMode`
   **暂停**该元素上所有 `ref.watch` 的订阅。被暂停期间 provider 照样在变
   （同步引擎在写库、drift 流在推），但这些订阅收不到。
2. 切回该分支 → `TickerMode` 变 true → `didUpdateWidget` →
   `_updateEffectiveMode()` → `ValueNotifier.value=` → `_updateTickerMode()` →
   `subscription.resume()`。**这一切发生在 build 阶段**（`didUpdateWidget`
   是树在重建时调的）。
3. `resume()` 里 `_listenedElement.flush()` 把暂停期间积压的脏值重放出来。
   重放沿依赖链一路重建（`_maybeRebuildDependencies` → `visitAncestors` →
   `flush` → `_performRebuild` → `_notifyListeners`）。
4. 链上某个 provider 的 `ref.watch` 回调 `invalidateSelf`。3.4.3 里这一步虽然在
   `_isFlushing` 期间会被挡掉，但重放本身还没结束 —— 只要**重放发生在
   `onSubscriptionResumeOrReactivate`（即 `super.resume()` / reactivate）那一步
   之后**，被恢复的订阅就会立刻收到脏值回调，其 `invalidateSelf` 就已经出了
   `_isFlushing` 窗口，于是照排刷新，一脚踢到 `UncontrolledProviderScope`。

只有「依赖链有分叉」时才炸（一条直链不会）：直链上 flush 到叶子就结束了，
分叉时第一条分支的重建把第二条分支也标脏，第二条的 `invalidateSelf` 才落到
那个正在 build 的元素上。所以它看着像偶发，其实取决于依赖图形状 —— 这个 app
里 `mailListProvider` / `mailboxFilterSelectionProvider` / `syncOverviewProvider`
那一片正好是分叉的。

## 补丁做了什么

**把 `flush()` 挪到 `onSubscriptionResumeOrReactivate()` 之前。** 这样暂停期间
积压的重放发生在任何元素被「恢复」**之前**，重放过程中的 `invalidateSelf` 都
还在 `_isFlushing` 窗口里（被 3.4.3 的 `!_isFlushing` 挡掉），等真正的
resume/reactivate 跑时已经没有待重放的脏值了。

上游 3.4.3 的顺序是：

```dart
_listenedElement.onSubscriptionResumeOrReactivate(this, applyResume);
_listenedElement.flush();
```

补丁把它换成：

```dart
// BEGIN PATCH(cloud-mail): resume 之前先 flush，见 third_party/PATCHES.md
_listenedElement.flush();
// END PATCH(cloud-mail)

_listenedElement.onSubscriptionResumeOrReactivate(this, applyResume);
```

这与上游主分支 PR #4884 的改法一字不差（那版是 `_listenedElement?.flush();
_listenedElement?.onSubscriptionResumeOrReactivate(this, applyResume);`）。

## 验证

回归测试在 `mail-app/test/ticker_resume_build_test.dart`，一共五条：直链、
左优先菱形、右优先菱形、嵌套菱形，外加一条来回切 `IndexedStack` 分支的。
每条都断言两件事 —— 恢复时**不抛异常**，而且恢复后**界面真的拿到新值**
（不抛但卡在旧值同样是坏的，只是不会报错）。

- 未打补丁的上游 3.4.3：四条「暂停后恢复」里的三条菱形**全红**（复现原始
  崩溃）；直链过，切分支那条**也过** —— 它钉的不是这个崩溃，而是「来回切之后
  订阅还活着、可见那一支跟得上值」这个不报错的坏法。所以它不构成复现，只是
  修完之后的一道护栏，别把它当成验证补丁有没有打上去的依据。
- 打上这一处：五条全绿，且 `mail-app` 全量测试 233 条全过、`flutter analyze`
  干净；真机上宽屏侧栏 / 窄屏底部导航来回切分支，异常不再出现。

失败的长相是可分辨的，重跑时看这两点就够了：

- **没打全**：`setState() or markNeedsBuild() called during build`，栈顶是
  `_UncontrolledProviderScopeState.scheduleRefresh` ← `ProviderElement.invalidateSelf`
  ← `ProviderSubscriptionImpl.resume` ← `ConsumerStatefulElement._updateTickerMode`。
- **打过头**（例如把 `flush()` 挪到了 `_onChangeSubscription` 之外，会触发
  上游那句 `Expected subscription to be part of this provider element` 断言）：
  报的是布局期另一个 assert，不是上面那条。

## 补丁的保鲜期

这不是长久方案，是**一段有明确删除条件的过渡**：等上游把 PR #4884 合并进发行版
（3.4.4 或更高），就直接删掉 `third_party/`、删掉 `pubspec.yaml` 里的
`dependency_overrides`、把 `flutter_riverpod` 的约束改成那个版本。删除步骤写在
`README.md` 末尾。

补丁本身是逐字照抄上游 PR 的实现，所以将来对比上游源码时不会有「我们自己发挥了
什么」的歧义。
