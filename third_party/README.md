# `third_party/` —— vendor 进来的、打了补丁的依赖

这里只有**一个**包：`riverpod`。

它不是「我们自己的代码」，是上游 `pub.dev` 上的 `riverpod 3.4.3` 打了一处补丁后的
源码副本。放在仓库里是为了让 `flutter pub get` 在所有机器上都拿到**同一份**代码，
而不是让每个人各自去改 `~/.pub-cache`。

## 为什么需要它

详情见 `PATCHES.md`。一句话：`flutter_riverpod` 3.4.3（当前最新一版）在「被
`TickerMode` 暂停的消费者恢复可见」时仍会抛
`setState() or markNeedsBuild() called during build`（菱形依赖图下必现）。上游
主分支的 PR #4884 修掉了它，但**还没合并进任何发行版** —— 只能把那一处回移。

> 历史：上一轮是 `riverpod 3.3.2` + 三处回移（因为当时本机 Dart 3.11.5 编译不了
> 3.4.x）。升到 Flutter 3.47.7 / Dart 3.13.5 之后，3.4.x 能编了，其中两处修复
> 也已经在 3.4.3 里，于是这份副本缩成「3.4.3 + 一处」。

## 目录

```
third_party/
├── README.md     ← 你在这里
├── PATCHES.md    ← 补丁清单、上游出处、验证方式
└── riverpod/     ← vendor：上游 riverpod 3.4.3 的 lib/ + pubspec + 补丁
```

## 怎么接进构建

`mail-app/pubspec.yaml` 里只需覆盖**一个**包：

```yaml
dependency_overrides:
  riverpod:
    path: third_party/riverpod
```

`flutter_riverpod` 不用覆盖也不用 vendor：它 3.4.3 对 `riverpod` 是**精确约束**
（`riverpod: 3.4.3`），版本号对得上，path 覆盖照样生效 —— 这一点在
`pubspec.lock` 里看得出来（`flutter_riverpod` 仍是 hosted 的 3.4.3，
`riverpod` 那一项是 `source: path`）。

**注意路径是相对 `pubspec.yaml` 所在的 `mail-app/` 写的**，不是相对仓库根。

## 什么时候可以删掉这个目录

当 `flutter_riverpod` 出现**含 PR #4884 的那个发行版**时（3.4.4 或更高；去
`rrousselGit/riverpod` 的 CHANGELOG 里搜 “diamond” 或那笔 commit）：

1. 删掉 `third_party/`；
2. 从 `mail-app/pubspec.yaml` 里删掉上面那段 `dependency_overrides`；
3. 把 `flutter_riverpod` 的约束从 `^3.4.3` 改成那个新版本；
4. 跑一遍 `mail-app/test/ticker_resume_build_test.dart`（那五条回归测试
   在上游版本里也应该过 —— 如果不过，说明上游又有了新形状的问题，值得去
   `rrousselGit/riverpod` 开一个 issue）。

## 怎么更新这里的副本

从 pub 上下载对应版本的 tarball，只取 `lib/`（`test/`、`doc/`、`example/`
都不要，那几个目录里有几十 MB 的生成物）：

```sh
curl -sL -o /tmp/riverpod.tar.gz "https://pub.flutter-io.cn/api/archives/riverpod-3.4.3.tar.gz"
mkdir -p /tmp/riverpod && tar xzf /tmp/riverpod.tar.gz -C /tmp/riverpod
cp -R /tmp/riverpod/lib third_party/riverpod/
cp /tmp/riverpod/LICENSE /tmp/riverpod/README.md /tmp/riverpod/CHANGELOG.md third_party/riverpod/
```

`pubspec.yaml` 里要手动删掉上游 monorepo 的内部字段 `resolution: workspace`，
其余照抄。然后按 `PATCHES.md` 重新打补丁。**不要**顺手升级版本号：换个版本
意味着补丁要重写，而这一份的意义恰恰是「钉住某个已知可用的版本 + 一段已知
可验证的修复」。

`lib/` 之外的三个文件（`LICENSE` / `README.md` / `CHANGELOG.md`）只是为了让
这份副本带上许可证与出处。`CHANGELOG.md` 里 3.4.x 那几段恰好就是 `PATCHES.md`
引用的上游出处，留着方便对照。
