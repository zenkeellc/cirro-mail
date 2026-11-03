#!/usr/bin/env python3
"""从公开标志 SVG 生成全平台应用图标。

## 图标长什么样

黑底圆角卡片 + 白色云朵 + 蓝色信封：

```
┌──────────────────┐  黑色圆角卡片（macOS / Linux / Windows / Android legacy）
│            ☁☁☁☁  │  ├─ 后层：白色云朵（从信封右上角探出来）
│  ┌──────────┐    │  └─ 前层：蓝色信封
│  │  信封    │    │
│  └──────────┘    │
└──────────────────┘
```

深色 Dock / 深色壁纸上，纯黑图标会和背景融成一块；所以**云朵是白色的**：它把
剪影边界画出来，信封再靠颜色对比落在云上。

## 源文件

| 文件 | 角色 |
|---|---|
| `assets/branding/cirro-mail-icon.svg` | **唯一设计源**：1024² 画布，黑底卡片 + 白云 + 蓝信封 |
| `assets/branding/cirro-mail-master.png` | 由它导出的母版：透明底「云 + 信封」，位置与 SVG 逐像素一致 |

母版是**摘掉卡片层**（SVG 里 `id="card"` 那个 `<g>`）之后光栅化的结果。卡片必须由
本脚本按平台规则现画 —— iOS 要方形铺满、Android 要透明前景、各家圆角也不同 ——
所以母版不能带底。母版已入库，平时出图标只依赖 Pillow；只有**改了 SVG**才需要
重新导出母版（那一步需要 SVG 光栅器）。

## 用法（在 `mail-app/` 根目录，需要 Pillow）

    python3 tool/gen_icons.py              # 母版 → 全部平台图标
    python3 tool/gen_icons.py --from-svg   # 先由 SVG 重导母版，再出图标（需要光栅器）
    python3 tool/gen_icons.py --check      # 只核对产物清单，不写文件

`--from-svg` 按 **cairosvg → rsvg-convert → sips(macOS) → inkscape** 的顺序找
光栅器，找到一个就用；一个都没有就报错退出。SVG 的 `width`/`height` 是 1024，
所以导出的母版是 1024²。

## 产物

| 文件 | 说明 |
|---|---|
| `assets/branding/cirro-mail-master.png` | 母版（1024²，透明底），**由 SVG 导出、入库** |
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
  缩到 **67.8%** 留安全区（与母版相同的构图，只是整体缩小）。
- **Android 圆形**：黑色正圆 + 圆内缩进 86% 的构图，圆外透明。
- 其它平台：**22.37% 圆角**的黑色卡片，四角透明（macOS 11 以来的图标形状）——
  这个圆角与设计稿 SVG 里的卡片一致，别改成别的比例。
- 母版里「云朵 + 信封」的**构图是设计稿定的**（整体包围盒宽 = 画布 86%、居中）。
  脚本不重排、不缩放构图，只把母版铺到各平台画布上。

## 改完之后

    python3 tool/gen_icons.py --check

改 SVG 之后重跑 `--from-svg` 就是全新的一套图标；`--check` 负责核对清单。
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

SOURCE_SVG = ROOT / 'assets/branding/cirro-mail-icon.svg'
MASTER = ROOT / 'assets/branding/cirro-mail-master.png'
MASTER_SIZE = 1024

# 卡片层在 SVG 里是 `<g id="card">…</g>`；出母版时整组摘掉。
CARD_RE = re.compile(r'\s*<g id="card">.*?</g>', re.S)

# ---- 图标构图（全部相对目标画布的比例） -------------------------------------
TILE_RADIUS = 0.2237        # macOS 11+ / 圆角黑卡片的圆角（与设计稿 SVG 一致）
CARD = (3, 4, 5)            # 卡片/背景：设计稿的 #030405
CIRCLE_SCALE = 0.86         # Android 圆形图标里构图的缩放，云朵四角才不被圆切掉
ADAPTIVE_SCALE = 0.6778     # Android 自适应前景缩放（沿用既有安全区）

SS = 4                      # 卡片合成超采样倍数（母版是 1024² 位图，不再矢量绘制）


def _save(im: Image.Image, path: Path, *, opaque: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if opaque:
        im.convert('RGB').save(path, optimize=True)
    else:
        im.save(path, optimize=True)


def _load_master() -> Image.Image:
    if not MASTER.exists():
        raise SystemExit(f'!! 缺母版 {MASTER.relative_to(ROOT)}，先跑 --from-svg')
    im = Image.open(MASTER).convert('RGBA')
    if im.size != (MASTER_SIZE, MASTER_SIZE):
        raise SystemExit(f'!! 母版 {im.size}，应为 {MASTER_SIZE}²')
    return im


def _rasterize(svg_text: str, out: Path) -> None:
    """把（已摘掉卡片层的）SVG 光栅化成 MASTER_SIZE² 透明底 PNG。"""
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='gen_icons_') as tmp:
        src = Path(tmp) / 'icon.svg'
        src.write_text(svg_text, encoding='utf-8')

        def sh(*cmd: str) -> bool:
            try:
                subprocess.run(cmd, check=True, capture_output=True)
                return True
            except (OSError, subprocess.CalledProcessError):
                return False

        if _try_cairosvg(src, out):
            pass
        elif (rsvg := _which('rsvg-convert')) and sh(
                rsvg, '-w', str(MASTER_SIZE), '-h', str(MASTER_SIZE), '-o', str(out), str(src)):
            pass
        elif (sips := _which('sips')) and sh(sips, '-s', 'format', 'png', str(src), '--out', str(out)):
            pass
        elif (inkscape := _which('inkscape')) and sh(
                inkscape, '--export-type=png', f'--export-width={MASTER_SIZE}',
                f'--export-filename={out}', str(src)):
            pass
        else:
            raise SystemExit('!! 没有可用的 SVG 光栅器（cairosvg / rsvg-convert / sips / inkscape 都没有）')

    im = Image.open(out).convert('RGBA')
    if im.size != (MASTER_SIZE, MASTER_SIZE):
        im = im.resize((MASTER_SIZE, MASTER_SIZE), Image.LANCZOS)
    _save(im, out)


def _try_cairosvg(src: Path, out: Path) -> bool:
    try:
        import cairosvg  # type: ignore
    except ImportError:
        return False
    try:
        cairosvg.svg2png(url=str(src), write_to=str(out),
                         output_width=MASTER_SIZE, output_height=MASTER_SIZE)
        return out.exists()
    except OSError:
        return False


def _which(name: str) -> str | None:
    import shutil
    return shutil.which(name)


def _card(size: int, bg: str) -> Image.Image:
    """`bg`：`card` 黑色圆角卡片 / `square` 黑色方形（iOS）/ `circle` 黑色正圆。"""
    big = size * SS
    out = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    layer = Image.new('RGBA', (big, big), CARD + (255,))
    if bg == 'square':
        out.alpha_composite(layer)
    else:
        mask = Image.new('L', (big, big), 0)
        radius = big / 2 if bg == 'circle' else TILE_RADIUS * big
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1],
                                               radius=radius, fill=255)
        out.alpha_composite(Image.composite(layer, Image.new('RGBA', (big, big), (0, 0, 0, 0)), mask))
    return out.resize((size, size), Image.LANCZOS)


def _art(master: Image.Image, px: int) -> Image.Image:
    """母版缩到 `px`²：构图/位置原样保留。"""
    return master.resize((px, px), Image.LANCZOS)


def _icon(size: int, master: Image.Image, bg: str) -> Image.Image:
    """黑色底 + 母版（平台图标：卡片 / 方形）。"""
    out = _card(size, bg)
    out.alpha_composite(_art(master, size))
    return out


def _circle_icon(size: int, master: Image.Image) -> Image.Image:
    """圆形图标：黑色正圆 + 缩进一圈的构图（云朵四角不会被圆切掉）。"""
    out = _card(size, 'circle')
    inner = round(size * CIRCLE_SCALE)
    out.alpha_composite(_art(master, inner), ((size - inner) // 2, (size - inner) // 2))
    return out


def _adaptive_foreground(size: int, master: Image.Image) -> Image.Image:
    """自适应图标前景：去掉黑底的构图，缩到安全区，透明底。"""
    inner = round(size * ADAPTIVE_SCALE)
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(_art(master, inner), ((size - inner) // 2, (size - inner) // 2))
    return canvas


def write_master() -> None:
    """由 SVG 重导母版：摘掉卡片层，只留透明底「云 + 信封」。"""
    text = SOURCE_SVG.read_text(encoding='utf-8')
    art = CARD_RE.sub('', text)
    if '<g id="card">' in art:
        raise SystemExit(f'!! {SOURCE_SVG.relative_to(ROOT)} 里没找到 <g id="card">，无法摘掉卡片层')
    _rasterize(art, MASTER)
    print(f'母版  {MASTER.relative_to(ROOT)}  {MASTER_SIZE}²（透明底「云 + 信封」）')


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


def check() -> int:
    """核对产物清单：尺寸、iOS 不透明、ICO 帧。"""
    bad = 0
    expect: list[tuple[Path, int, bool]] = []
    if not MASTER.exists():
        print(f'!! 缺母版 {MASTER.relative_to(ROOT)}', file=sys.stderr)
        bad += 1
    elif Image.open(MASTER).size != (MASTER_SIZE, MASTER_SIZE):
        print(f'!! 母版尺寸 {Image.open(MASTER).size}，应为 {MASTER_SIZE}²', file=sys.stderr)
        bad += 1
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
    ap.add_argument('--from-svg', action='store_true', help='先由 SVG 重导母版（需要光栅器）')
    args = ap.parse_args()

    if args.check:
        return 1 if check() else 0

    if args.from_svg:
        write_master()
    master = _load_master()
    write_icons(master)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
