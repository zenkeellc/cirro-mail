/// 地址归一化 + 「这封信属于哪个邮箱」的反查。
///
/// 为什么需要它：本地判断一封邮件的归属只有地址这一个线索 —— 服务端的
/// 摘要列（`emailBriefColumns`，`/email/latest` 恒定用它）**不带** `accountId`，
/// 而 `toEmail`（收信投递到哪个邮箱）/ `sendEmail`（发信从哪个邮箱发出）
/// 是准的。`mailboxes` 表里有权威的 `邮箱地址 → accountId` 映射，
/// 两者一撮合就能把归属补回来。
///
/// 投递地址可能带 `+tag`（站内信、订阅地址：`news+abc@x.com` 也是投给
/// `news@x.com` 的那个邮箱），所以匹配要「先精确、后退回基址」。这套规则
/// 必须**只有一处实现** —— 写库时（`EmailRepository._persist`）和历史数据
/// 回填时（`MailDao.reassignAccountIds`）用的是同一份逻辑，否则两边会得出
/// 不同的归属，那种 bug 极难看出来。
library;

/// 地址 → `accountId` 的反查表。键**必须是** [normalizeEmail] 处理过的形式。
typedef AccountIdByEmail = Map<String, int>;

/// 归一化：[trim] + 小写。
///
/// 本地部分理论上区分大小写，实际没人这么用，而「同一地址写成两种大小写
/// 导致查不到」是更常见的故障，所以统一折叠。
String normalizeEmail(String email) => email.trim().toLowerCase();

/// `news+abc@x.com` → `news@x.com`。不合法（缺 `@` 或多段 `@`）返回原串。
String baseEmailOf(String email) {
  final parts = email.split('@');
  if (parts.length != 2) return email;
  return '${parts.first.split('+').first}@${parts.last}';
}

/// 在 [byEmail] 里查 [address] 对应的 `accountId`。查不到返回 null。
///
/// 顺序：精确 → 去掉 `+tag` 的基址。反过来会把 `a+b@x.com` 错误地
/// 归到 `a@x.com`，而 `a+b@x.com` 完全可能是自己一个独立邮箱。
int? accountIdForEmail(AccountIdByEmail byEmail, String address) {
  final candidate = normalizeEmail(address);
  if (candidate.isEmpty || !candidate.contains('@')) return null;

  final exact = byEmail[candidate];
  if (exact != null) return exact;

  final base = baseEmailOf(candidate);
  if (base == candidate) return null;
  return byEmail[base];
}

/// 这个地址**格式上**是否合法。
///
/// 这是 `mail-worker/src/utils/verify-utils.js` 里 `isEmail` 那个正则的
/// **逐字翻译** —— 一个字符都不许改：
///
/// ```js
/// /^[a-zA-Z0-9!#$%&'*+/=?^_`{|}~.-]+@([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$/
/// ```
///
/// 为什么必须逐字照抄：这是「本地预校验」（省一次注定失败的往返）与
/// 「服务端 `notEmail`」之间的唯一契约。两套规则一旦有差集，差集里的每个
/// 地址都会得到两种结论 —— 本地拦掉的地址服务端其实收（用户被无故挡在
/// 门外），或本地放过去、服务端回 501（用户看不懂那句中英文混合的错误）。
///
/// 三点刻意的「不」：
/// - **不 trim**。服务端 `isEmail(email)` 拿到的是原样入参，带空格的照样挡。
///   这里 trim 一下会把「本地过、服务端挡」变成默认行为。
/// - **不小写**。大小写都在字符集里，`A@B.CO` 是合法的。
/// - **不校验顶级域是不是真实存在**。服务端也没有，那是 DNS 的事。
///
/// 注意与 [normalizeEmail] 的分工：那个是**归属判断**的归一化（trim + 小写），
/// 与「格式是否合法」是两件事，别混用。
bool isEmailAddress(String value) => _emailPattern.hasMatch(value);

/// 与 worker 的 `isEmail` 逐字对应的正则。
///
/// 用 `raw` 字符串：里面同时有 `` ` `` 和 `$`，普通字符串里 `$` 会开始一次
/// 插值（紧接着的 `%` 不是标识符也不算括号，编译期直接报错）。
final RegExp _emailPattern = RegExp(
  r"^[a-zA-Z0-9!#$%&'*+/=?^_`{|}~.-]+@([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$",
);
