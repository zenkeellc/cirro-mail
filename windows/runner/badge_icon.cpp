#include "badge_icon.h"

#include <gdiplus.h>

#include <algorithm>
#include <string>

namespace {

// 角标底色取 #D93025（「未读红」）：白字压上去对比度够，而且任务栏/通知区
// 本身是深色的，红块与 App 图标的蓝色也不会糊在一起。
constexpr Gdiplus::ARGB kBadgeColor = 0xFFD93025;

// GDI+ 的初始化/反初始化各是一次全局状态切换。徽章只在未读数变化时重画
// （一次点击打开一封信的频率），不值得让进程从启动起就常驻 GDI+ 状态；
// 单次 `GdiplusStartup` 的开销在这个尺度上忽略不计。
//
// RAII 是必须的：这个函数有十来条失败返回路径，手工 `Shutdown` 迟早漏一条，
// 漏掉的那次之后 GDI+ 就半死不活。析构保证每条路都收尾。
class GdiplusSession {
 public:
  GdiplusSession() {
    Gdiplus::GdiplusStartupInput input;
    ok_ = Gdiplus::GdiplusStartup(&token_, &input, nullptr) == Gdiplus::Ok;
  }

  ~GdiplusSession() {
    if (ok_) {
      Gdiplus::GdiplusShutdown(token_);
    }
  }

  GdiplusSession(const GdiplusSession&) = delete;
  GdiplusSession& operator=(const GdiplusSession&) = delete;

  bool ok() const { return ok_; }

 private:
  ULONG_PTR token_ = 0;
  bool ok_ = false;
};

}  // namespace

HICON CreateBadgeIcon(HICON base, int count, int size) {
  if (base == nullptr || count <= 0 || size <= 0) {
    return nullptr;
  }

  GdiplusSession gdiplus;
  if (!gdiplus.ok()) {
    return nullptr;
  }

  // 底图用 GDI+ 的 `Bitmap(HICON)` 解，而不是 `DrawIconEx`：后者会把图标
  // AND 掩码的透明区域画成黑色，角标的透明边角就变成一个黑框。`Bitmap`
  // 走的是 alpha 通道，`.ico` 里那一档的圆角透明区能原样保留。
  Gdiplus::Bitmap base_image(base);
  if (base_image.GetLastStatus() != Gdiplus::Ok) {
    return nullptr;
  }

  Gdiplus::Bitmap canvas(size, size, PixelFormat32bppARGB);
  if (canvas.GetLastStatus() != Gdiplus::Ok) {
    return nullptr;
  }

  Gdiplus::Graphics graphics(&canvas);
  if (graphics.GetLastStatus() != Gdiplus::Ok) {
    return nullptr;
  }
  // 抗锯齿是这段代码存在的理由：不做的话 16px 的圆边和数字全是台阶。
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
  graphics.Clear(Gdiplus::Color(0x00000000));

  // 底图缩放到目标尺寸。正常路径上两者相等（1:1，不经过缩放），这里写成
  // 目标矩形是为了「调用方传错了尺寸」时不至于画出一张裁掉一半的图标。
  graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  const Gdiplus::REAL edge = static_cast<Gdiplus::REAL>(size);
  const Gdiplus::Status base_status = graphics.DrawImage(
      &base_image, Gdiplus::RectF(0.0f, 0.0f, edge, edge), 0.0f, 0.0f,
      static_cast<Gdiplus::REAL>(base_image.GetWidth()),
      static_cast<Gdiplus::REAL>(base_image.GetHeight()),
      Gdiplus::UnitPixel);
  if (base_status != Gdiplus::Ok) {
    return nullptr;
  }

  // 数字上限 99+：三位数在 16px 的圆里本来就放不下，这是桌面角标的通行上限。
  // Dart 侧传的是原始数，截断放在这里，五个平台各画各的、口径一致。
  const std::wstring text = count > 99 ? L"99+" : std::to_wstring(count);
  const int text_length = static_cast<int>(text.size());

  // 白圈 + 红圆，贴在右下角。
  //
  // 圈宽至少 1px：再细等于没有。`margin` 留出的正好是圈宽 —— 白圈贴到图标
  // 边缘会被裁成一条直切线，看起来像图标坏了。
  // 直径取 11/16：16px 上 11px、32px 上 22px。再大就把底图盖没了（16px
  // 的图标上只看得见红圈），再小则一位数字都放不下。
  const int ring = std::max(1, size / 32);
  const int diameter = std::max(8, (size * 11) / 16);
  const int margin = ring;
  const int left = size - margin - diameter;
  const int top = size - margin - diameter;
  const Gdiplus::RectF badge_rect(static_cast<Gdiplus::REAL>(left),
                                  static_cast<Gdiplus::REAL>(top),
                                  static_cast<Gdiplus::REAL>(diameter),
                                  static_cast<Gdiplus::REAL>(diameter));

  // 字体优先 Segoe UI（Windows 上数字形状最规整），没有就退回 GDI+ 的
  // 通用无衬线族。粗体：白字在红底上不加粗，16px 时就只有一两个像素宽。
  Gdiplus::FontFamily installed_family(L"Segoe UI");
  const Gdiplus::FontFamily* family =
      installed_family.GetLastStatus() == Gdiplus::Ok
          ? &installed_family
          : Gdiplus::FontFamily::GenericSansSerif();
  if (family == nullptr) {
    return nullptr;
  }

  // 起始字号按字符数分档：一个数字尽量占满圆，两个收一点，「99+」再收一点。
  // 之后还要按实际测量继续缩 —— 不同系统上的 Segoe UI 度量有细微差别，
  // 硬编码一个字号在 16px 上很容易把「99+」挤出圆外。
  Gdiplus::REAL font_size =
      static_cast<Gdiplus::REAL>(diameter) *
      (text_length == 1 ? 0.68f : (text_length == 2 ? 0.54f : 0.44f));

  Gdiplus::StringFormat format;
  format.SetAlignment(Gdiplus::StringAlignmentCenter);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);

  // 左右各留 1px 呼吸边，避免数字贴着圆边看着像被啃掉一口。
  const Gdiplus::REAL max_width = static_cast<Gdiplus::REAL>(diameter) - 2.0f;
  for (int attempt = 0; attempt < 8; ++attempt) {
    Gdiplus::Font probe(family, font_size, Gdiplus::FontStyleBold,
                        Gdiplus::UnitPixel);
    if (probe.GetLastStatus() != Gdiplus::Ok) {
      return nullptr;
    }
    Gdiplus::RectF measured;
    if (graphics.MeasureString(text.c_str(), text_length, &probe, badge_rect,
                               &format, &measured) != Gdiplus::Ok) {
      return nullptr;
    }
    if (measured.Width <= max_width || font_size <= 4.0f) {
      break;
    }
    font_size -= 0.5f;
  }

  Gdiplus::Font font(family, font_size, Gdiplus::FontStyleBold,
                     Gdiplus::UnitPixel);
  if (font.GetLastStatus() != Gdiplus::Ok) {
    return nullptr;
  }

  // 花括号而不是圆括号：`SolidBrush brush(Color(argb))` 会被当成函数声明
  // （most vexing parse），编译器只在部分写法上才报警。
  Gdiplus::SolidBrush ring_brush{Gdiplus::Color(0xFFFFFFFF)};
  Gdiplus::SolidBrush badge_brush{Gdiplus::Color(kBadgeColor)};
  Gdiplus::SolidBrush text_brush{Gdiplus::Color(0xFFFFFFFF)};

  const Gdiplus::REAL ring_edge =
      static_cast<Gdiplus::REAL>(diameter + 2 * ring);
  const Gdiplus::Status ring_status = graphics.FillEllipse(
      &ring_brush, Gdiplus::RectF(static_cast<Gdiplus::REAL>(left - ring),
                                  static_cast<Gdiplus::REAL>(top - ring),
                                  ring_edge, ring_edge));
  if (ring_status != Gdiplus::Ok) {
    return nullptr;
  }
  const Gdiplus::Status badge_status =
      graphics.FillEllipse(&badge_brush, badge_rect);
  if (badge_status != Gdiplus::Ok) {
    return nullptr;
  }
  const Gdiplus::Status text_status = graphics.DrawString(
      text.c_str(), text_length, &font, badge_rect, &format, &text_brush);
  if (text_status != Gdiplus::Ok) {
    return nullptr;
  }

  // 32bpp + alpha 的 HICON：Windows Vista 之后任务栏/通知区都按 alpha 合成，
  // 透明边角不会出现黑边。
  HICON icon = nullptr;
  if (canvas.GetHICON(&icon) != Gdiplus::Ok || icon == nullptr) {
    return nullptr;
  }
  return icon;
}
