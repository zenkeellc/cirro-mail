# 版本号与更新检查

App 怎么知道「自己是什么版本」、怎么知道「有没有新版」、发布的人怎么把新版告诉所有客户端。三件事各管一段：**build 号来自 git**，**版本清单是官网上的一个静态 JSON**，**发布时用脚本改那个 JSON**。

本文写给两类人：想自己打包的（第二、三节）与负责发版的（第四、五节）。只想把自动检查关掉的普通用户看第六节。

---

## 一、版本号从哪来

版本号不手工维护，全由 git 推出来：

| 值 | 来源 | 注入的编译期变量 |
|---|---|---|
| 版本名（`0.1.0`） | 最近的 git tag，**去掉前缀 `v` 与渠道标记**（`v0.1.0-pro.1` → `0.1.0`，见下）；没有 tag 时退回 `pubspec.yaml` 的版本 | `APP_VERSION_NAME` |
| build 号（正整数） | `git rev-list --count HEAD` | `APP_BUILD_NUMBER` |
| 提交（短 sha） | `git rev-parse --short HEAD` | `APP_GIT_SHA` |
| 构建时间（UTC，ISO 8601，秒精度） | 构建那一刻，如 `2026-11-02T02:39:46Z` | `APP_BUILD_TIME` |
| 渠道（`public` / `pro`） | 构建参数，默认 `public` | `APP_UPDATE_CHANNEL` |

**build 号 = 提交数**是这套东西的根：每提交一次，tag 不用动，build 号自己 +1，所以两个不同 build 的产物一定对应不同的提交。打新版本的 tag 只决定「版本名」，不决定 build 号。

### 渠道标记只活在 tag 上

两个客户端是一条代码线的两份构建，tag 是唯一会撞名的地方：商业检出里同一版必须叫 `v0.1.4-pro.1`（否则与公开仓的 `v0.1.4` 在 fetch 时会打架）。但 `-pro.1` **不属于版本号**：

- 用户看到的版本号（关于页、窗口标题、更新清单）描述的是软件本身，渠道由 `APP_UPDATE_CHANNEL` 表达；
- 商业版的产品名里已经有一个 `Pro`，`Cirro Mail Pro v0.1.4-pro.1+86` 里的第二个 `pro` 只是噪音；
- 产物名 / 清单 / 注入值必须是**同一个数**，否则「App 里显示 0.1.4、清单里写着 0.1.4-pro.1」的版本比较会判反方向。

规则写在 `tool/src/version_core.dart` 的 `stripChannelMarker`：tag 结尾是 `-<本次渠道>.<数字>` 时把它去掉（`v0.1.4-pro.1` + `--channel=pro` → `0.1.4`）。**渠道对不上时不去**，并且 `tool/version.dart` 会打一条警告 —— 那多半是忘了 `--channel=pro`，发出去的包会显示 `0.1.4-pro.1`。显式 `APP_VERSION_NAME`（发版补包时钉版）永远原样采信。

⚠️ **CI 里 checkout 必须 `fetch-depth: 0`**（完整历史）。浅克隆算出来的 `git rev-list --count HEAD` 永远是 1 —— 工具会为此在 stderr 打一条警告，但出来的包 build 号就是错的，而且不容易发现。

**平台包的版本字段只写数字主体**：`--build-name` 用版本名去掉预发布标识之后的数字主体（`0.1.0`）。原因是平台各有硬性规则 —— Apple 的 `CFBundleShortVersionString` 只允许数字与点，Windows 的 CMake 还要按 `.` 把它拆成整数的 major/minor/patch。`dart tool/version.dart --format=build-args` 的输出里能同时看到版本名与这个数字主体。

这些值在编译期用 `--dart-define` 注入。**没注入时**（直接 `flutter run`、或没走包装脚本的 `flutter build`）App 退回 `PackageInfo`，也就是 `pubspec.yaml` 里那个 `0.1.0+1` —— 能跑、能显示，但 build 号不会随提交走。所以**要发出去的包一律走第三节的包装脚本**。

### 发布时把版本写回 pubspec（`tool/bump.dart`）

上面那套是**构建期**注入，只活在这一次构建里。仓库里的 `pubspec.yaml` 如果一直停在手写基线 `0.1.0+1`，那么任何不走 `tool/build.dart` 的 `flutter run` / `flutter build`（开发时、照 README 自己打包的人）看到的就都是 0.1.0 —— 关于页、窗口标题、平台包的版本字段全是它。

所以发版脚本在**打 tag 之前**把版本写回仓库：

```bash
dart tool/bump.dart --version=0.1.10 --build=104 --channel=public   # 真写
dart tool/bump.dart --dry-run --format=paths                       # 只算，只打印
dart tool/bump.dart --check                                        # 只校验（发版检查清单用）
```

写这几类文件（`--format=paths` 输出改动清单，发版脚本拿它 `git add`）：

| 文件 | 写成什么 | 谁写 |
|---|---|---|
| 根 `pubspec.yaml` | `<版本名>+<build 号>` | **只在公开渠道写**。商业检出的根版本随公开 `main` 合并过来（发版门禁本来就要求先合并公开 `main`）—— 在 pro 里写同一行，下一轮合并必然撞车 |
| 内部包 `packages/<名字>/pubspec.yaml` | 版本名 | 按渠道：公开渠道写检出里的**全部**内部包；商业渠道只用 `--package=` 点名它自己的商业包 —— 两个检出逐字节相同的共享包只在公开检出写，在这边改会被 `check_public_sync.sh` 当未登记差异拒绝出包 |
| 上面这些包在锁文件里的 `version:` | 同步 | 同上 —— 不改的话下一次 `pub get` 立刻把工作区弄脏 |

「一个文件只有一个作者」不是洁癖：两个检出的同步就是 `git merge`，同一行两边都改，每次发版都要解一次冲突。pro 检出的根 `pubspec.yaml` 靠合并公开 `main` 拿到同一版（发版门禁本来就要求公开 `main` 已合并进 pro）。

`.release/scripts/release-all.sh` 会在打 tag 前自动做这一步，并提交一次 `chore(release): 版本 → 0.1.10+104（public）`，tag 落在这个提交上；`--skip-version-sync` 可以关掉。注意写进 pubspec 的 build 号是**提交之后**的提交数（提交会让提交数 +1），也就是构建真正注入的那个数。

界面上版本串的格式是 `0.1.0+131`（版本名 + build 号）：关于页与桌面窗口标题都用它（窗口标题多了应用名，见 `window_title.dart` 的 `Cirro Mail v0.1.0+131`）。build 号为 0（不知道）时只显示版本名。

## 二、`tool/version.dart`：只算版本，不构建

```bash
dart tool/version.dart                      # = --format=summary，人读的摘要（默认）
dart tool/version.dart --format=shell       # KEY='value' 行，可直接 eval（发版脚本用）
dart tool/version.dart --format=json        # 机器读（CI / 发布脚本解析用）
dart tool/version.dart --build-args         # = --format=build-args，只输出 flutter build 参数串
dart tool/version.dart --channel=pro        # 换发行渠道（默认 public）
```

四种格式：

| 格式 | 给谁 | 内容 |
|---|---|---|
| `summary`（默认） | 人 | 版本名、build 号及其来源、提交、构建时间（UTC）、渠道、工作区是否 dirty，外加一行注入参数 |
| `shell` | 发布脚本 | `APP_VERSION_NAME='0.1.0'` 这种 `KEY='value'` 行；`eval "$(dart tool/version.dart --format=shell)"` 之后变量可直接用。另外给出 `VERSION_NAME` / `BUILD_NUMBER` / `CHANNEL`，方便拼发布文件名 |
| `json` | CI / 脚本 | `{versionName, buildNumber, commit, builtAt, channel, dirty, shallow, display, sources}`；`builtAt` 是秒精度 UTC（`2026-11-02T02:39:46Z`） |
| `build-args`（=`--build-args`） | `flutter build` | 一行 `--build-name=… --build-number=… --dart-define=APP_VERSION_NAME=… …`；值里没有空格，可以安全地按空白切分 |

- `--build-args` 只打印参数串，不构建；想手写 `flutter build` 时把它拼在后面即可（等价写法见下一节的对照）。
- `--channel=<名字>` 决定注入的 `APP_UPDATE_CHANNEL`。优先级：`--channel` > 环境变量 `APP_UPDATE_CHANNEL` > `public`。**渠道名只影响客户端读版本清单里的哪个渠道**，不影响版本号，核心代码也不关心它叫什么。
- `--repo=<目录>` 指定从哪个检出算版本（默认是本工具所在的检出）。另一个发行渠道的检出还没合入这个工具时，可以临时指过去借用，版本按那个仓库算。
- 给人看的是 `summary`，给脚本用的是 `shell` / `json`。**不要解析 `summary` 的文本**。

## 三、`tool/build.dart`：构建时自动注入

包装脚本，收的是原样的 `flutter build` 参数，自己把版本相关的 flag 和 dart-define 补上：

```bash
dart tool/build.dart macos --release
dart tool/build.dart linux --release
dart tool/build.dart windows --release
dart tool/build.dart apk --debug
dart tool/build.dart --dry-run macos --release   # 只打印最终命令，不执行
dart tool/build.dart apk --release --channel=pro  # 换渠道（包装层吃掉 --channel）
```

`--dry-run` / `--channel=…` / `--repo=…` / `--help` 由包装层吃掉，**其余参数原样透传**给 `flutter build`（所以 `--dart-define=APP_UPDATE_CHANNEL=pro` 这种手写参数也会照常交给 flutter）。自己传过的 `--build-name` / `--build-number` / 同名 `APP_*` define 不会被重复追加 —— **显式值优先**。`--dry-run` 打印的最终命令可以直接复制出来手动跑，CI 日志里也会先打这一行。

它等价于先跑一遍 `tool/version.dart --build-args`，再执行：

```bash
flutter build macos --release \
  --build-name=0.1.0 \
  --build-number=131 \
  --dart-define=APP_VERSION_NAME=0.1.0 \
  --dart-define=APP_BUILD_NUMBER=131 \
  --dart-define=APP_GIT_SHA=<short sha> \
  --dart-define=APP_BUILD_TIME=2026-11-02T02:40:00Z \
  --dart-define=APP_UPDATE_CHANNEL=public
```

想换渠道又不想用 `--channel` 时，也可以直接把那个 define 透传给包装脚本（`dart tool/build.dart macos --release --dart-define=APP_UPDATE_CHANNEL=pro`）。两种写法效果相同 —— 但**一个包只能有一个渠道**，别在 wrapper 与手写参数里各写一个；真撞上了，显式传的那个优先。

## 四、版本清单长什么样

客户端查新版本**只读一个静态文件**：

```
https://cirro.zenkee.com/app-version.json
```

源文件是官网仓库里的 `mail-site/public/app-version.json`，Cloudflare Pages 部署时**原样**发布（不经过任何接口、不鉴权、不代表「在线服务」）。schema 固定为：

```json
{
  "schema": 1,
  "updatedAt": "2026-11-02T02:40:00Z",
  "channels": {
    "public": {
      "version": "0.1.0",
      "buildNumber": 1,
      "publishedAt": "2026-10-28T14:00:46Z",
      "notes": "首个公开发布：多实例、AI 写信、附件预览。First public release.",
      "releaseUrl": "https://github.com/zenkeellc/cirro-mail/releases/tag/v0.1.0",
      "downloads": {
        "macos": "https://github.com/zenkeellc/cirro-mail/releases/download/v0.1.0/CirroMail-0.1.0-macos-universal.dmg",
        "linux": "https://github.com/zenkeellc/cirro-mail/releases/download/v0.1.0/CirroMail-0.1.0-linux-x86_64.tar.gz",
        "windows": null,
        "android": null,
        "ios": null
      }
    },
    "pro": { "…同构…": "另一个发行渠道的条目" }
  }
}
```

字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `schema` | number | 固定 `1`；改结构才升，客户端不认别的值 |
| `updatedAt` | string | 清单最近一次被改的时间（ISO 8601，带时区） |
| `channels` | object | 渠道名 → 该渠道的最新版本；`public` 与 `pro` 两个键都在 |
| `version` | string | 版本名 = tag 去掉 `v` 与渠道标记，如 `0.1.0`（`v0.1.4-pro.1` 写 `0.1.4`） |
| `buildNumber` | number | 正整数，`git rev-list --count HEAD` |
| `publishedAt` | string | 这个版本发布的时间（ISO 8601，带时区） |
| `notes` | string | 一句话更新说明，**纯文本**（可空串）；客户端直接显示，不放 HTML |
| `releaseUrl` | string | release 页地址（https），平台直链缺失时回退到它 |
| `downloads` | object | 五个平台键 `macos` / `linux` / `windows` / `android` / `ios`，值是 https 直链或 `null` |

**字段名与类型是契约**：客户端按 `schema: 1` 校验，认不出的 schema 按坏数据处理（**不猜**），文件不是合法 JSON 时提示「检查失败」。所以改清单时宁可留 `null`、留空 `notes`，也别省字段、别改类型 —— 类型错了客户端不会当没事发生。

**客户端怎么判断「有没有新版」**：先比 `version`（semver；预发布按 semver §11 排序，所以 `0.1.0-beta.1 < 0.1.0`），版本名相同才比 `buildNumber`。**不是**「buildNumber 大就新」——`0.2.0+1` 比 `0.1.0+999` 新。当前运行版本未知时不做判断，按「已是最新」处理、不弹提示。渠道标记不进 `version`（见第一节），所以同一版的两个渠道各自比的是同一个数字、靠 `buildNumber` 分先后。

`channels` 里为什么有两个渠道：同一份构建参数只注入一个 `APP_UPDATE_CHANNEL`，客户端只读自己那个渠道。`public` 是公开仓库发的版本；`pro` 是商业版（私有仓库）发的版本，两边各自独立比较。

**`pro` 渠道的下载地址与公开渠道不同**：安装包不放在公开 release 里（私有仓 release 未登录访问会 404，别往清单里写），但仍然**给直链** —— `downloads.macos` / `downloads.linux` / `downloads.android` 是网关的公开直出地址 `https://ai.cirro.zenkee.com/v1/download/{macos,linux,android}`，**不需要登录、不需要订阅、不需要任何 token**（2026-11-08 晚起；安装包仍在 R2 私有桶 `cirro-pro`，由网关按 `pro/index.json` 流式发出，见 `mail-ai/README.md` 的「Pro 安装包分发」）。`windows` / `ios` 没有产物，写 `null`；`releaseUrl` 仍指向官网下载页 `https://cirro.zenkee.com/pro/download/`，作为客户端没有直链时的回退（见第七节「先直链、后 release 页」）。这三条地址与版本无关，发版时只需要改版本三件套。

## 五、发布时怎么更新清单

发布是两步：**先发 GitHub Release，再改官网清单**。清单更新后，已经装了旧版的客户端下一次检查就会看到新版本。

1. **发 tag + Release**（照旧流程），拿到 tag，例如 `v0.2.0`。

2. **取真实资产地址**（不要手拼，资产名随平台/架构会变）：

   ```bash
   gh release view v0.2.0 -R zenkeellc/cirro-mail --json assets,url
   ```

   从 `assets[].url` 里取 macOS 的 `.dmg`、Linux 的 `.tar.gz`（或 `.deb`）、Windows 的 `.zip` 等；**这个仓库当前只发桌面端，`windows` / `android` / `ios` 没有产物就写 `null`**。

   这一步只适用于 `public` 渠道。`pro` 渠道没有 GitHub 资产（私有仓 release 未登录访问会 404，别往清单里写），安装包由 `mail-ai/tool/upload-pro-downloads.mjs` 传到 R2 私有桶，清单只改版本三件套（见下面的说明）。

3. **改清单**（在父仓库的 `mail-site/` 目录下跑；脚本无第三方依赖）：

   ```bash
   node scripts/app-version.mjs \
     --channel public \
     --version 0.2.0 \
     --build 132 \
     --release-url https://github.com/zenkeellc/cirro-mail/releases/tag/v0.2.0 \
     --macos-url https://github.com/zenkeellc/cirro-mail/releases/download/v0.2.0/CirroMail-0.2.0-macos-universal.dmg \
     --linux-url https://github.com/zenkeellc/cirro-mail/releases/download/v0.2.0/CirroMail-0.2.0-linux-x86_64.tar.gz \
     --notes-file /tmp/notes.txt
   ```

   - `--build` 用 `dart tool/version.dart --format=json`（或 `--format=shell`）给出的数，别手数提交。
   - `--notes-file` 与 `--notes "一句话"` 二选一；说明别超过一两句纯文本。
   - 只想改某个平台直链时只传对应的 `--macos-url` 等，其余字段保持原样；传空值（如 `--ios-url=`）会写成 `null`。
   - 脚本自动刷新 `updatedAt`；只有 `version` 或 `buildNumber` 真的变了才刷新该渠道的 `publishedAt`（修一处下载地址或说明不算新版本）。
   - 写回固定 2 空格缩进、末尾换行、键顺序稳定，diff 只动该动的行。

4. **校验**（`--check` 只校验、不写盘，适合放进 CI）：

   ```bash
   node scripts/app-version.mjs --check
   ```

   校验失败（schema 不对、版本名带 `v`、build 不是正整数、URL 不是 https、平台键拼错、缺 `null` 平台……）会**列出每一条错误并以非零退出码结束**。验收线上文件时也可以直接 `curl -s https://cirro.zenkee.com/app-version.json | python3 -m json.tool`。

5. **提交并部署**：把 `mail-site/public/app-version.json` 的改动提交、推到 `main`。官网的 GitHub Actions 会在改动落在 `mail-site/**` 时跑构建与测试并部署到 Cloudflare Pages；部署完成后 <https://cirro.zenkee.com/app-version.json> 就是新内容。**不需要重启任何服务**。

> 发 `pro` 渠道：`--channel pro`，`--release-url https://cirro.zenkee.com/pro/download/`，**通常只改 `--version` / `--build` / `--notes` 三件套** —— `downloads` 里那三条网关公开直链（`https://ai.cirro.zenkee.com/v1/download/{macos,linux,android}`）与版本无关，不要动；只有某个平台确实没有产物时才把它传空写成 `null`（`--android-url=`）。**不要把私有仓库的 release 资产地址写进清单**（未登录 404）。版本名照旧去掉 `-pro.N`（写 `0.1.4` 而不是 `0.1.4-pro.1`，脚本会拒绝后者）。安装包上传走 `mail-ai/tool/upload-pro-downloads.mjs`，网关按 `pro/index.json` 公开直出，下载不需要登录或订阅。清单里两个渠道互不影响，所以「公开版先发、商业版晚一天」也没问题。

## 六、隐私与关闭

**客户端请求什么、不请求什么：**

- 只有 `GET https://cirro.zenkee.com/app-version.json` 这一个请求（带一个 `?_=<毫秒时间戳>` 的 cache-buster，避免 CDN 缓存把新清单挡住；超时 8 秒）。域名就是官网域名，清单地址可替换，见下。
- 不带账号、不带邮件内容、不带设备标识；不要求登录、不写 cookie；这个文件是静态的，服务端拿不到「谁在升级」。
- 不自动下载、不自动安装：有新版时只显示版本说明 + 打开下载页/直链，装不装由用户决定。
- 自动检查默认开启，启动时最多一天一次（同一台机器 24 小时内不重复打网络）。
- 检查失败（断网、超时、静态站把未知路径回成 200 + HTML、schema 不认识）时关于页显示「检查失败」+ 一句本地化提示（「请检查网络连接后再试」）+「重试」。**原始错误文本不上屏**（Dio/网络报错可能是英文，用户可见文案一律走 l10n），只留在 `UpdateException` 里给测试与诊断；静态站的 200+HTML 也走这条，不会被当成「已是最新」。

**三种关法：**

| 场景 | 做法 |
|---|---|
| 打包时彻底关掉（自建 / 只想自己控制） | `--dart-define=APP_UPDATE_MANIFEST=`（**空串**）—— 关于页整块「检查更新 + 自动检查开关」都隐藏，只留版本信息，也不再发任何请求 |
| 指向自己的清单 | `--dart-define=APP_UPDATE_MANIFEST=https://你的域名/app-version.json`（任何静态 JSON 地址都行，照第四节的 schema 放好即可） |
| 用户自己不想被自动检查 | 关于页的「自动检查更新」开关（偏好存本地）：**只停启动时的自动检查**，版本照常显示，手动点「检查」仍然可用 |

关闭清单地址（第一个）是**编译期的**：装好的包改不了，要重新打包。其余两个是运行时的。另外 `--dart-define=APP_UPDATE_CHECK=false` 只改「自动检查」的**默认值**（用户仍可在关于页打开），它**不是**关闭入口 —— 要彻底关掉用第一个。

## 七、平台下载与回退

运行平台按 `defaultTargetPlatform` 映射到清单里的键（android / ios / macos / windows / linux）。有新版时客户端按「先直链、后 release 页」的顺序给下载地址：

1. `downloads.<当前平台>` 有 https 直链 → 直接用它；
2. 是 `null`（或空串）→ 用 `releaseUrl`（release 页面上有全部资产，含 `SHA256SUMS.txt`）；
3. 两者都没有 → **不出现「下载」按钮**，只展示 `notes`。

当前的实际状态（两个渠道分开看）：`public` 渠道 macOS 与 Linux 有直链，`windows` / `android` / `ios` 是 `null`（还没有这些平台的产物），所以这三个平台一律回退到 release 页；`pro` 渠道 macOS / Linux / Android 三条都是网关公开直链，`windows` / `ios` 是 `null`。直链缺失的平台回退到 `releaseUrl` —— 对 `pro` 那次回退落在官网下载页，那一页也是公开的（不需要登录）。以后补了产物，按第五节把对应 `--windows-url` 等填上即可，客户端不用改。

关于页那一块长这样：版本行（`0.1.0+131`）、构建提交/构建时间/渠道小字、「检查更新」区域（手动「检查」按钮 + 「自动检查更新」开关）。检查结果就地显示：检查中 / 已是最新（+ 重新检查）/ 发现新版本（+ 清单 `notes` 原样展示 +「下载」「稍后」）/ 检查失败（+「重试」）。启动时发现新版本另弹一条提示，动作是「下载」，点提示文字进设置页（关于分类在最后一项；设置页目前没有 `?section=about` 这类深链，只能先到设置首页）。下载走系统浏览器/外部打开，不在 App 内安装。

## 八、发版检查清单

- [ ] tag 已推、GitHub Release 已发，资产可下载
- [ ] `dart tool/version.dart --format=summary` 的版本名/build 号与要发的包一致
- [ ] 版本已写回仓库：`git log -1` 能看到 `chore(release): 版本 → …`（发版脚本自动做），或手动跑过 `dart tool/bump.dart --check`
- [ ] `node scripts/app-version.mjs --check` 通过
- [ ] 新清单比旧的大（先比 `version`、再比 `buildNumber`），`releaseUrl` 与平台直链能打开
- [ ] 清单提交并部署后，`curl -s https://cirro.zenkee.com/app-version.json | python3 -m json.tool` 能看到新版本
- [ ] 拿一个旧包启动，关于页能提示新版本（有测试包时）

---

## 相关文档

- [`push-setup.md`](push-setup.md)：内置推送（与更新检查无关，独立配置）
- 官网仓库的 `mail-site/README.md`：站点部署流程（`public/` 下的文件会原样进 `dist/`，清单就是其中一件）
- 清单生成脚本：`mail-site/scripts/app-version.mjs`（`--help` 看全部参数）
