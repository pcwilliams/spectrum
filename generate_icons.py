#!/usr/bin/env python3
"""Generate Spectrum app icons (standard, dark, tinted) at 1024x1024.
Inspired by the app's spectrum analyser display — stylised frequency bars
with the signature blue-cyan-green-yellow-red gradient on a dark background.
"""

from PIL import Image, ImageDraw, ImageFilter
import math
import random

random.seed(42)

SIZE = 1024
SUPER = 3  # supersampling factor for anti-aliasing
SS = SIZE * SUPER


def draw_spectrum_icon(bg, bar_colors, glow_color, reflection_alpha, output_path):
    """Draw a stylised spectrum analyser icon with gradient bars."""
    img = Image.new("RGB", (SS, SS), bg)
    draw = ImageDraw.Draw(img)

    # Icon geometry
    margin = int(SS * 0.15)
    bar_area_bottom = int(SS * 0.72)
    bar_area_top = int(SS * 0.12)
    bar_area_width = SS - 2 * margin
    num_bars = 16
    bar_gap = int(bar_area_width * 0.04)
    bar_width = (bar_area_width - (num_bars - 1) * bar_gap) // num_bars

    # Spectrum shape — a smooth curve peaking in the low-mid frequencies
    # Mimics a typical audio spectrum with a strong low-mid hump
    bar_heights = []
    for i in range(num_bars):
        t = i / (num_bars - 1)
        # Peak around 25% (low-mid frequencies), decay toward highs
        h = math.exp(-((t - 0.22) ** 2) / 0.06) * 0.95
        # Add a secondary smaller peak around 55%
        h += math.exp(-((t - 0.55) ** 2) / 0.04) * 0.4
        # Gentle noise for organic feel
        h += random.uniform(-0.03, 0.03)
        h = max(0.08, min(1.0, h))
        bar_heights.append(h)

    # Subtle radial glow behind the bars
    glow_radius = int(SS * 0.35)
    gcx, gcy = SS // 2, int(SS * 0.45)
    for step in range(glow_radius, 0, -SUPER):
        t = step / glow_radius
        t = t * t  # ease out
        c = tuple(int(glow_color[j] + (bg[j] - glow_color[j]) * t) for j in range(3))
        draw.ellipse((gcx - step, gcy - step, gcx + step, gcy + step), fill=c)

    draw = ImageDraw.Draw(img)

    # Draw bars
    for i in range(num_bars):
        x = margin + i * (bar_width + bar_gap)
        h = bar_heights[i]
        bar_top = int(bar_area_bottom - h * (bar_area_bottom - bar_area_top))

        # Gradient fill for each bar — sample from the colour ramp
        color_t = i / (num_bars - 1)
        bar_color = interpolate_gradient(bar_colors, color_t)

        # Draw bar with slight rounded top
        radius = min(bar_width // 3, 8 * SUPER)
        draw.rounded_rectangle(
            (x, bar_top, x + bar_width, bar_area_bottom),
            radius=radius,
            fill=bar_color
        )

        # Brighter top highlight
        highlight = tuple(min(255, c + 40) for c in bar_color)
        draw.rounded_rectangle(
            (x, bar_top, x + bar_width, bar_top + max(2, int(4 * SUPER))),
            radius=radius,
            fill=highlight
        )

        # Subtle reflection below (dimmed mirror)
        if reflection_alpha > 0:
            refl_height = int((bar_area_bottom - bar_top) * 0.25)
            refl_top = bar_area_bottom + int(SS * 0.02)
            refl_color = tuple(max(0, int(c * reflection_alpha)) for c in bar_color)
            draw.rounded_rectangle(
                (x, refl_top, x + bar_width, refl_top + refl_height),
                radius=radius,
                fill=refl_color
            )

    # Peak dots above some bars
    peak_bars = [1, 2, 3, 5, 8, 11]
    for i in peak_bars:
        if i < num_bars:
            x = margin + i * (bar_width + bar_gap)
            h = min(1.0, bar_heights[i] + random.uniform(0.04, 0.10))
            peak_y = int(bar_area_bottom - h * (bar_area_bottom - bar_area_top))
            color_t = i / (num_bars - 1)
            peak_color = interpolate_gradient(bar_colors, color_t)
            peak_color = tuple(min(255, c + 60) for c in peak_color)
            dot_r = int(bar_width * 0.35)
            cx = x + bar_width // 2
            draw.ellipse(
                (cx - dot_r, peak_y - dot_r, cx + dot_r, peak_y + dot_r),
                fill=peak_color
            )

    # Downscale with high-quality resampling
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(output_path, "PNG")
    print(f"Saved: {output_path} ({img.size[0]}x{img.size[1]})")


def interpolate_gradient(colors, t):
    """Interpolate through a list of (r,g,b) colour stops at position t (0-1)."""
    t = max(0.0, min(1.0, t))
    n = len(colors) - 1
    idx = t * n
    i = int(idx)
    frac = idx - i
    if i >= n:
        return colors[-1]
    c0, c1 = colors[i], colors[i + 1]
    return tuple(int(c0[j] + (c1[j] - c0[j]) * frac) for j in range(3))


# --- Generate all three variants ---

BASE = "/Users/pwilliams/appledev/spectrum/Spectrum/Assets.xcassets/AppIcon.appiconset"

# Standard icon — dark background with vibrant spectrum gradient
draw_spectrum_icon(
    bg=(12, 12, 22),
    bar_colors=[
        (0, 100, 255),    # blue (bass)
        (0, 210, 255),    # cyan
        (0, 230, 130),    # green
        (255, 210, 0),    # yellow
        (255, 60, 20),    # red (treble)
    ],
    glow_color=(20, 25, 50),
    reflection_alpha=0.15,
    output_path=f"{BASE}/spectrum_icon.png",
)

# Dark icon — deeper background, slightly cooler tones
draw_spectrum_icon(
    bg=(8, 8, 18),
    bar_colors=[
        (0, 80, 220),     # deeper blue
        (0, 190, 240),    # cyan
        (0, 210, 110),    # green
        (240, 195, 0),    # yellow
        (240, 50, 15),    # red
    ],
    glow_color=(15, 18, 38),
    reflection_alpha=0.10,
    output_path=f"{BASE}/spectrum_icon_dark.png",
)

# Tinted icon — greyscale
draw_spectrum_icon(
    bg=(14, 14, 14),
    bar_colors=[
        (100, 100, 100),  # dark grey (bass)
        (140, 140, 140),  # mid grey
        (175, 175, 175),  # light grey
        (200, 200, 200),  # lighter
        (160, 160, 160),  # mid again (treble)
    ],
    glow_color=(25, 25, 25),
    reflection_alpha=0.08,
    output_path=f"{BASE}/spectrum_icon_tinted.png",
)

print("All icons generated!")
