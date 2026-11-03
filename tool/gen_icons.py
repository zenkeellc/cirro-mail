#!/usr/bin/env python3
"""从公开标志母版生成全平台应用图标。

## 图标长什么样

黑底卡片 + 白色云朵 + 蓝色信封：

```
┌──────────────┐  黑色圆角卡片（macOS / Linux / Windows / Android legacy）
│              │  ├─ 后层：白色云朵（一朵，平底，三个云包）
│  ┌────────┐  │  └─ 前层：蓝色信封（母版 `cirro-mail-master.png`）
│  │  信封  │  │
│  └────────┘  │
│   ☁☁☁☁☁     │
└──────────────┘
```

深色 Dock / 深色壁纸上，纯黑图标会和背景融成一块；所以**云朵是白色的**：它把
剪影边界画出来，信封再靠颜色对比落在云上。商业版只把信封换成金色，卡片、云朵、
构图一个像素都不动（见 `mail-app-pro/tool/gen_pro_icons.py`）。

## 母版

`assets/branding/cirro-mail-master.png` —— 1254²、透明底、**只有信封标志**，
不含黑底和云朵；黑底与云朵由本脚本在出图标时合成。母版本身由 `--master` 按
矢量几何重渲染：信封是 180:128 的圆角矩形 + 翻盖折线 + 纸面，颜色全部走
`palette(s)` 这一条映射，所以改配色/比例只要动上面的常量。

## 用法（在仓库根目录，需要 Pillow）

    python3 tool/gen_icons.py             # 母版 → 全部平台图标
    python3 tool/gen_icons.py --master    # 先按常量重渲染母版，再出图标
    python3 tool/gen_icons.py --check     # 只核对产物清单，不写文件

## 产物

| 文件 | 说明 |
|---|---|
| `assets/branding/cirro-mail-master.png` | 标志母版（1254²，透明底），**唯一源文件** |
| `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png` | macOS，7 档，透明圆角卡片 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png` | iOS，15 档，**不透明**（App Store 不收带 alpha 的图），方形铺满、由系统切圆角 |
| `android/app/src/main/res/mipmap-*/ic_launcher{,_round,_foreground}.png` | Android，5 档 × {legacy 卡片 / 圆形 / 自适应前景} |
| `linux/runner/resources/hicolor/*/apps/cirro-mail.png` | Linux 桌面主题图标，9 档 |
| `windows/runner/resources/app_icon.ico` | Windows，7 档 ICO |

## 构图规则（别「顺手统一样式」）

- **iOS**：方形铺满（黑色到边）——系统自己切圆角，图标里再画圆角会变成双圆角；
  且必须不透明。
- **Android 自适应**：背景色在 `mipmap-anydpi-v26/*.xml` 里
  （`@color/ic_launcher_background` = 纯黑）；前景层是**去掉黑底**的云朵 + 信封，
  缩到 **67.8%** 留安全区。
- **Android 圆形**：黑色正圆 + 圆内缩进 86% 的构图，圆外透明。
- 其它平台：**22.37% 圆角**的黑色卡片，四角透明（macOS 11 以来的图标形状）。

## 改完之后

    python3 tool/gen_icons.py --check

商业版是同形的金色版本：改完这里，去 `mail-app-pro` 同步母版并重出图标。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

MASTER = ROOT / 'assets/branding/cirro-mail-master.png'
MASTER_SIZE = 1254

# ---- 标志几何：信封在 192×192 的参考网格里 -----------------------------------
# 外框 180×128（1.406:1）、圆角 14；翻盖从左上/右上两角折到 (95.5, 100)，折线宽
# 8；纸面是 45° 的倒三角，尖在 (95.5, 68.5)。这些数是从上游 192px 原图量出来的，
# 改之前先按 512px 预览核对。
BOXX = (6, 32, 186, 160)
BOX_R = 14
APEX = (95.5, 100.0)
PAPER_APEX = (95.5, 68.5)
BAND = 8

# 明暗分层：s = 0 最深（折线阴影 / 主体下沿），s = 1 最亮（翻盖高光）。同一套 s
# 值在公开版映射成蓝、在商业版映射成金，所以两边的立体层次完全一致。
S_BODY_TOP, S_BODY_BOT = 0.63, 0.02
S_PAPER_TOP, S_PAPER_BOT = 0.76, 0.55
S_FLAP_TOP, S_FLAP_BOT = 1.00, 0.86
S_BAND = 0.22

# 蓝：s=0 → #0075FF，s=1 → #00C0FF（标志原色：青色到蓝的渐变）
BLUE = ((0, 117, 255), (0, 192, 255))

# ---- 图标构图（全部相对目标画布的比例） -------------------------------------
TILE_RADIUS = 0.2237        # macOS 11+ 图标的圆角
CARD = (0, 0, 0)            # 卡片/背景：纯黑
CLOUD_COLOR = (255, 255, 255)
CLOUD_W = 0.98              # 云宽；底边落在 0.83 处，信封从云里升出来
CLOUD_BOTTOM = 0.83
CLOUD_BASE_H = 0.21         # 平底厚度（云宽的倍数）：三个云包的交点约在 0.187
                            # 处，底座再薄就会在包与包之间漏出黑三角
ENV_W = 0.60                # 信封宽度；中心 0.42 —— 云包的肩正好露在信封两侧
ENV_CY = 0.42
ADAPTIVE_SCALE = 0.6778     # Android 自适应前景缩放（沿用既有安全区）
CIRCLE_SCALE = 0.86         # Android 圆形图标里构图的缩放，云朵四角才不被圆切掉

SS = 4                      # 合成超采样倍数


def _lerp(c0: tuple[int, int, int], c1: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    return tuple(round(a + (b - a) * t) for a, b in zip(c0, c1))


def palette(s: float) -> tuple[int, int, int]:
    """明暗 s（0 深、1 亮）→ 颜色。改配色只动 `BLUE` 这一处。"""
    return _lerp(BLUE[0], BLUE[1], s)


def _envelope(width: int, ss: int = SS) -> Image.Image:
    """按参考网格渲染透明底信封，`width` 是信封外框宽度（像素）。"""
    u = width / (BOXX[2] - BOXX[0])
    w, h = width, round((BOXX[3] - BOXX[1]) * u)
    cw, ch = w * ss, h * ss

    def X(x: float) -> float:
        return (x - BOXX[0]) * u * ss

    def Y(y: float) -> float:
        return (y - BOXX[1]) * u * ss

    out = Image.new('RGBA', (cw, ch), (0, 0, 0, 0))

    body = Image.new('L', (cw, ch), 0)
    ImageDraw.Draw(body).rounded_rectangle(
        [X(BOXX[0]), Y(BOXX[1]), X(BOXX[2]), Y(BOXX[3])], radius=BOX_R * u * ss, fill=255)

    paper = Image.new('L', (cw, ch), 0)
    ImageDraw.Draw(paper).polygon(
        [(X(PAPER_APEX[0]), Y(PAPER_APEX[1])), (X(BOXX[2]), Y(BOXX[3])),
         (X(BOXX[0]), Y(BOXX[3]))], fill=255)

    flap = Image.new('L', (cw, ch), 0)
    ImageDraw.Draw(flap).polygon(
        [(X(BOXX[0]), Y(BOXX[1])), (X(APEX[0]), Y(APEX[1])),
         (X(BOXX[2]), Y(BOXX[1]))], fill=255)

    band = Image.new('L', (cw, ch), 0)
    dband = ImageDraw.Draw(band)
    cap = BAND * u * ss / 2
    for corner in ((BOXX[0], BOXX[1]), (BOXX[2], BOXX[1])):
        dband.line([X(corner[0]), Y(corner[1]), X(APEX[0]), Y(APEX[1])],
                   fill=255, width=round(BAND * u * ss), joint='curve')
        dband.ellipse([X(APEX[0]) - cap, Y(APEX[1]) - cap,
                       X(APEX[0]) + cap, Y(APEX[1]) + cap], fill=255)

    def shade(s_top: float, s_bot: float) -> Image.Image:
        strip = Image.new('RGBA', (1, ch))
        for y in range(ch):
            strip.putpixel((0, y), palette(s_top + (s_bot - s_top) * y / (ch - 1)) + (255,))
        return strip.resize((cw, ch), Image.NEAREST)

    for layer, mask in (
        (shade(S_BODY_TOP, S_BODY_BOT), body),
        (shade(S_PAPER_TOP, S_PAPER_BOT), paper),
        (shade(S_FLAP_TOP, S_FLAP_BOT), flap),
        (Image.new('RGBA', (cw, ch), palette(S_BAND) + (255,)), band),
    ):
        layer.putalpha(mask)
        out.alpha_composite(layer)

    return out.resize((w, h), Image.LANCZOS)


def _cloud_mask(px: int) -> Image.Image:
    """白色云朵的 alpha：平底 + 三个云包。"""
    m = Image.new('L', (px, px), 0)
    d = ImageDraw.Draw(m)
    u = CLOUD_W * px
    x0 = px / 2 - u / 2
    y1 = CLOUD_BOTTOM * px

    def puff(lx: float, ly: float, r: float) -> None:
        cx, cy, rr = x0 + lx * u, y1 - ly * u, r * u
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=255)

    d.rounded_rectangle([x0 + 0.05 * u, y1 - CLOUD_BASE_H * u, x0 + 0.95 * u, y1],
                        radius=0.09 * u, fill=255)
    puff(0.20, 0.28, 0.175)
    puff(0.50, 0.34, 0.215)
    puff(0.80, 0.28, 0.175)
    return m


def _mark(master: Image.Image, width: int, ss: int = 1) -> Image.Image:
    """把母版裁到内容 bbox，再缩成指定宽度的信封。"""
    bbox = master.getchannel('A').getbbox()
    if bbox is None:
        raise SystemExit('!! 母版是空的')
    mark = master.crop(bbox)
    return mark.resize((width, max(1, round(width * mark.height / mark.width))), Image.LANCZOS)


def _scene(px: int, master: Image.Image) -> Image.Image:
    """透明底构图（白色云朵 + 信封），直接画在 px×px 上。"""
    out = Image.new('RGBA', (px, px), (0, 0, 0, 0))
    cloud = Image.new('RGBA', (px, px), CLOUD_COLOR + (255,))
    cloud.putalpha(_cloud_mask(px))
    out.alpha_composite(cloud)
    mark = _mark(master, round(ENV_W * px))
    out.alpha_composite(mark, ((px - mark.width) // 2, round(ENV_CY * px - mark.height / 2)))
    return out


def _icon(size: int, master: Image.Image, bg: str) -> Image.Image:
    """`bg`：`card` 黑色圆角卡片 / `square` 黑色方形（iOS）/ `circle` 黑色正圆。"""
    big = size * SS
    out = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    card = Image.new('RGBA', (big, big), CARD + (255,))
    if bg == 'square':
        out.alpha_composite(card)
    else:
        mask = Image.new('L', (big, big), 0)
        radius = big / 2 if bg == 'circle' else TILE_RADIUS * big
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1],
                                               radius=radius, fill=255)
        out.alpha_composite(Image.composite(card, Image.new('RGBA', (big, big), (0, 0, 0, 0)), mask))
    out.alpha_composite(_scene(big, master))
    return out.resize((size, size), Image.LANCZOS)


def _circle_icon(size: int, master: Image.Image) -> Image.Image:
    """圆形图标：黑色正圆 + 缩进一圈的构图（云朵四角不会被圆切掉）。"""
    big = size * SS
    out = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(out).rounded_rectangle([0, 0, big - 1, big - 1], radius=big / 2,
                                          fill=CARD + (255,))
    inner = round(big * CIRCLE_SCALE)
    scene = _scene(inner, master)
    out.alpha_composite(scene, ((big - inner) // 2, (big - inner) // 2))
    return out.resize((size, size), Image.LANCZOS)


def _adaptive_foreground(size: int, master: Image.Image) -> Image.Image:
    """自适应图标前景：去掉黑底的构图，缩到安全区，透明底。"""
    big = size * SS
    scene = _scene(big, master)
    inner = round(size * ADAPTIVE_SCALE)
    scene = scene.resize((inner, inner), Image.LANCZOS)
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(scene, ((size - inner) // 2, (size - inner) // 2))
    return canvas


def _save(im: Image.Image, path: Path, *, opaque: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if opaque:
        im.convert('RGB').save(path)
    else:
        im.save(path)


def write_master() -> None:
    """按矢量几何重渲染标志母版（1254²，透明底）。"""
    width = round(0.87 * MASTER_SIZE)
    mark = _envelope(width)
    master = Image.new('RGBA', (MASTER_SIZE, MASTER_SIZE), (0, 0, 0, 0))
    master.alpha_composite(mark, ((MASTER_SIZE - mark.width) // 2,
                                  (MASTER_SIZE - mark.height) // 2))
    _save(master, MASTER)
    print(f'母版  {MASTER.relative_to(ROOT)}  {master.size[0]}²（信封宽 {width}px）')


def write_icons(master: Image.Image) -> None:
    """按各平台现有清单重写全部图标。"""
    # macOS：透明圆角卡片
    for size in (16, 32, 64, 128, 256, 512, 1024):
        _save(_icon(size, master, 'card'),
              ROOT / f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png')

    # iOS：不透明方形（系统切圆角）
    for name, size in [
        ('Icon-App-20x20@1x', 20), ('Icon-App-20x20@2x', 40), ('Icon-App-20x20@3x', 60),
        ('Icon-App-29x29@1x', 29), ('Icon-App-29x29@2x', 58), ('Icon-App-29x29@3x', 87),
        ('Icon-App-40x40@1x', 40), ('Icon-App-40x40@2x', 80), ('Icon-App-40x40@3x', 120),
        ('Icon-App-60x60@2x', 120), ('Icon-App-60x60@3x', 180),
        ('Icon-App-76x76@1x', 76), ('Icon-App-76x76@2x', 152),
        ('Icon-App-83.5x83.5@2x', 167), ('Icon-App-1024x1024@1x', 1024),
    ]:
        _save(_icon(size, master, 'square'),
              ROOT / f'ios/Runner/Assets.xcassets/AppIcon.appiconset/{name}.png',
              opaque=True)

    # Android：legacy 卡片 / 圆形 / 自适应前景（5 档密度）
    for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                          ('xxhdpi', 144), ('xxxhdpi', 192)]:
        base = ROOT / f'android/app/src/main/res/mipmap-{density}'
        _save(_icon(size, master, 'card'), base / 'ic_launcher.png')
        _save(_circle_icon(size, master), base / 'ic_launcher_round.png')
        _save(_adaptive_foreground(round(size * 2.25), master),
              base / 'ic_launcher_foreground.png')

    # Linux：桌面主题图标
    for size in (16, 22, 24, 32, 48, 64, 128, 256, 512):
        _save(_icon(size, master, 'card'),
              ROOT / f'linux/runner/resources/hicolor/{size}x{size}/apps/cirro-mail.png')

    # Windows：多尺寸 ICO
    ico_sizes = (16, 24, 32, 48, 64, 128, 256)
    frames = [_icon(s, master, 'card') for s in ico_sizes]
    frames[-1].save(ROOT / 'windows/runner/resources/app_icon.ico', format='ICO',
                    sizes=[(s, s) for s in ico_sizes], append_images=frames[:-1])

    print('图标  已重写（macOS 7 + iOS 15 + Android 5×3 + Linux 9 + Windows 7 档 ICO）')


def check(master: Image.Image) -> int:
    """核对产物清单：尺寸、iOS 不透明、ICO 帧。"""
    bad = 0
    expect: list[tuple[Path, int, bool]] = []
    for size in (16, 32, 64, 128, 256, 512, 1024):
        expect.append((ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
                       / f'app_icon_{size}.png', size, False))
    for name, size in [
        ('Icon-App-20x20@1x', 20), ('Icon-App-20x20@2x', 40), ('Icon-App-20x20@3x', 60),
        ('Icon-App-29x29@1x', 29), ('Icon-App-29x29@2x', 58), ('Icon-App-29x29@3x', 87),
        ('Icon-App-40x40@1x', 40), ('Icon-App-40x40@2x', 80), ('Icon-App-40x40@3x', 120),
        ('Icon-App-60x60@2x', 120), ('Icon-App-60x60@3x', 180),
        ('Icon-App-76x76@1x', 76), ('Icon-App-76x76@2x', 152),
        ('Icon-App-83.5x83.5@2x', 167), ('Icon-App-1024x1024@1x', 1024),
    ]:
        expect.append((ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset' / f'{name}.png',
                       size, True))
    for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                          ('xxhdpi', 144), ('xxxhdpi', 192)]:
        base = ROOT / f'android/app/src/main/res/mipmap-{density}'
        expect.append((base / 'ic_launcher.png', size, False))
        expect.append((base / 'ic_launcher_round.png', size, False))
        expect.append((base / 'ic_launcher_foreground.png', round(size * 2.25), False))
    for size in (16, 22, 24, 32, 48, 64, 128, 256, 512):
        expect.append((ROOT / 'linux/runner/resources/hicolor'
                       / f'{size}x{size}/apps/cirro-mail.png', size, False))
    for path, size, opaque in expect:
        if not path.exists():
            print(f'!! 缺文件 {path.relative_to(ROOT)}', file=sys.stderr)
            bad += 1
            continue
        im = Image.open(path)
        if max(im.size) != size:
            print(f'!! {path.relative_to(ROOT)} 尺寸 {im.size}，应为 {size}²', file=sys.stderr)
            bad += 1
        elif opaque and im.mode not in ('RGB', 'L'):
            print(f'!! {path.relative_to(ROOT)} 带 alpha，iOS 图标必须不透明', file=sys.stderr)
            bad += 1

    ico = ROOT / 'windows/runner/resources/app_icon.ico'
    if not ico.exists():
        print(f'!! 缺文件 {ico.relative_to(ROOT)}', file=sys.stderr)
        bad += 1
    else:
        sizes = sorted(Image.open(ico).info.get('sizes', ()))
        want = [(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
        if sizes != want:
            print(f'!! app_icon.ico 帧 {sizes}，应为 {want}', file=sys.stderr)
            bad += 1

    print('检查  通过' if bad == 0 else f'检查  {bad} 处不符')
    return bad


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--check', action='store_true', help='只检查，不写文件')
    ap.add_argument('--master', action='store_true', help='先按常量重渲染标志母版')
    args = ap.parse_args()

    if args.master and not args.check:
        write_master()
    if not MASTER.exists():
        print(f'!! 缺母版 {MASTER.relative_to(ROOT)}，先跑 --master', file=sys.stderr)
        return 2
    master = Image.open(MASTER).convert('RGBA')
    if master.size != (MASTER_SIZE, MASTER_SIZE):
        print(f'!! 母版 {master.size}，应为 {MASTER_SIZE}²', file=sys.stderr)
        return 2
    if args.check:
        return 1 if check(master) else 0
    write_icons(master)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
