from __future__ import annotations

import math
import os
from collections import deque
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path("/Users/david1/Documents/Code/Cursor/HandTrack")
MAC_APPICONSET = ROOT / "Apps/macOS/Resources/Assets.xcassets/AppIcon.appiconset"
MAC_MASTER = MAC_APPICONSET / "HandTrackAppIcon1024.png"
IOS_MASTER = ROOT / "Apps/iOS/Resources/Assets.xcassets/AppIcon.appiconset/HandTrackAppIcon1024.png"


def rounded_rect_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.21), fill=255)
    return mask


def glossy_blue_background(size: int, palette: str, rounded_alpha: bool) -> Image.Image:
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = bg.load()

    if palette == "light":
        top = (180, 222, 255)
        mid = (116, 184, 244)
        bottom = (49, 121, 217)
        shine_color = (255, 255, 255, 86)
        diagonal_color = (220, 245, 255, 54)
        vignette_alpha = 44
    else:
        top = (22, 60, 150)
        mid = (12, 36, 105)
        bottom = (5, 12, 48)
        shine_color = (72, 126, 230, 92)
        diagonal_color = (51, 94, 202, 36)
        vignette_alpha = 105

    for y in range(size):
        t = y / (size - 1)
        if t < 0.42:
            local = t / 0.42
            c0, c1 = top, mid
        else:
            local = (t - 0.42) / 0.58
            c0, c1 = mid, bottom
        r = int(c0[0] + (c1[0] - c0[0]) * local)
        g = int(c0[1] + (c1[1] - c0[1]) * local)
        b = int(c0[2] + (c1[2] - c0[2]) * local)
        for x in range(size):
            px[x, y] = (r, g, b, 255)

    # Soft glossy shine like the reference: a blue highlight in the upper-left,
    # not a pale rectangle.
    shine = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shine_draw = ImageDraw.Draw(shine)
    shine_draw.ellipse(
        (-int(size * 0.08), -int(size * 0.23), int(size * 0.98), int(size * 0.63)),
        fill=shine_color,
    )
    shine = shine.filter(ImageFilter.GaussianBlur(radius=int(size * 0.09)))
    bg = Image.alpha_composite(bg, shine)

    diagonal = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    diagonal_draw = ImageDraw.Draw(diagonal)
    diagonal_draw.polygon(
        [
            (0, int(size * 0.02)),
            (int(size * 0.72), 0),
            (int(size * 0.38), int(size * 0.36)),
            (0, int(size * 0.48)),
        ],
        fill=diagonal_color,
    )
    diagonal = diagonal.filter(ImageFilter.GaussianBlur(radius=int(size * 0.04)))
    bg = Image.alpha_composite(bg, diagonal)

    # Darken the outside edges for depth.
    vignette = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    vp = vignette.load()
    cx, cy = size * 0.47, size * 0.43
    max_dist = math.hypot(max(cx, size - cx), max(cy, size - cy))
    for y in range(size):
        for x in range(size):
            dist = math.hypot(x - cx, y - cy) / max_dist
            alpha = max(0, min(vignette_alpha, int((dist - 0.36) * 185)))
            vp[x, y] = (0, 0, 0, alpha)
    bg = Image.alpha_composite(bg, vignette)
    if rounded_alpha:
        bg.putalpha(rounded_rect_mask(size))
    return bg


def foreground_mask(source: Image.Image) -> Image.Image:
    width, height = source.size
    src = source.convert("RGBA")
    data = src.load()
    mask = Image.new("L", (width, height), 0)
    mp = mask.load()

    badge_cx, badge_cy, badge_r = width * 0.485, height * 0.628, width * 0.145
    for y in range(height):
        for x in range(width):
            r, g, b, a = data[x, y]
            if a == 0:
                continue

            in_badge = math.hypot(x - badge_cx, y - badge_cy) <= badge_r
            skin = r > 125 and g > 65 and b < 185 and r > g + 8 and g > b + 8
            pale_skin = r > 180 and g > 120 and b < 215 and r > b + 18
            white_badge_detail = in_badge and r > 210 and g > 210 and b > 210
            blue_badge = in_badge and b > 80 and r < 95 and g < 125
            badge_shadow = in_badge and r < 90 and g < 100 and b < 135

            if skin or pale_skin or white_badge_detail or blue_badge or badge_shadow:
                mp[x, y] = 255

    # Keep only sizable foreground components. This drops old background streaks.
    visited = bytearray(width * height)
    keep = Image.new("L", (width, height), 0)
    kp = keep.load()
    min_area = int(width * height * 0.00025)
    for start_y in range(height):
        for start_x in range(width):
            idx = start_y * width + start_x
            if visited[idx] or mp[start_x, start_y] == 0:
                continue

            points: list[tuple[int, int]] = []
            touches_foreground_zone = False
            q: deque[tuple[int, int]] = deque([(start_x, start_y)])
            visited[idx] = 1
            while q:
                x, y = q.popleft()
                points.append((x, y))
                if width * 0.18 < x < width * 0.86 and height * 0.04 < y < height:
                    touches_foreground_zone = True
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if nx < 0 or ny < 0 or nx >= width or ny >= height:
                        continue
                    nidx = ny * width + nx
                    if visited[nidx] or mp[nx, ny] == 0:
                        continue
                    visited[nidx] = 1
                    q.append((nx, ny))

            if touches_foreground_zone and len(points) >= min_area:
                for x, y in points:
                    kp[x, y] = 255

    keep = keep.filter(ImageFilter.MaxFilter(size=5)).filter(ImageFilter.GaussianBlur(radius=1.2))
    return keep


def rebuild_icon(source_path: Path, output_path: Path, palette: str, rounded_alpha: bool) -> None:
    """Replace only the background; keep the hand and green-plus badge artwork."""
    original = Image.open(source_path).convert("RGBA")
    if original.size != (1024, 1024):
        original = crop_center_square(original).resize((1024, 1024), Image.Resampling.LANCZOS)
    bg = glossy_blue_background(1024, palette=palette, rounded_alpha=rounded_alpha)
    mask = foreground_mask(original)
    foreground = Image.new("RGBA", original.size, (0, 0, 0, 0))
    foreground.paste(original, (0, 0), mask)
    rebuilt = Image.alpha_composite(bg, foreground)
    if not rounded_alpha:
        rebuilt = rebuilt.convert("RGB")
    rebuilt.save(output_path, "PNG")


def crop_center_square(image: Image.Image) -> Image.Image:
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    return image.crop((left, top, left + side, top + side))


def rebuild_dark_icon(path: Path) -> None:
    original = Image.open(path).convert("RGBA")
    if original.size != (1024, 1024):
        original = crop_center_square(original).resize((1024, 1024), Image.Resampling.LANCZOS)
    size = 1024
    bg = glossy_blue_background(size, palette="dark", rounded_alpha=True)
    mask = foreground_mask(original)
    foreground = Image.new("RGBA", original.size, (0, 0, 0, 0))
    foreground.paste(original, (0, 0), mask)
    rebuilt = Image.alpha_composite(bg, foreground)
    rebuilt.save(path, "PNG")


def generate_scaled_mac_icons() -> None:
    sizes = [
        (16, "mac_16.png"),
        (32, "mac_16_2x.png"),
        (32, "mac_32.png"),
        (64, "mac_32_2x.png"),
        (128, "mac_128.png"),
        (256, "mac_128_2x.png"),
        (256, "mac_256.png"),
        (512, "mac_256_2x.png"),
        (512, "mac_512.png"),
        (1024, "mac_512_2x.png"),
    ]
    master = Image.open(MAC_MASTER).convert("RGBA")
    for size, name in sizes:
        master.resize((size, size), Image.Resampling.LANCZOS).save(MAC_APPICONSET / name, "PNG")


def main() -> None:
    # Save a clean copy of the hand artwork before we start modifying files
    temp_source = ROOT / "hand_artwork_source.png"
    if not temp_source.exists():
        import shutil
        shutil.copy(MAC_MASTER, temp_source)
    
    rebuild_dark_icon(temp_source)
    # Overwrite MAC_MASTER with the dark version
    import shutil
    shutil.copy(temp_source, MAC_MASTER)
    
    # Now build the light version for iOS using the clean source
    rebuild_icon(temp_source, IOS_MASTER, palette="light", rounded_alpha=False)
    
    generate_scaled_mac_icons()
    print("Rebuilt macOS dark-blue icon and iOS light-blue icon.")


if __name__ == "__main__":
    main()
