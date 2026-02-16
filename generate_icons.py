#!/usr/bin/env python3
"""Generate Mellon Chat app icons for iOS and Android."""

from PIL import Image, ImageDraw, ImageFont
import math
import os


def create_gradient(size, color1, color2):
    """Create a diagonal gradient from top-left to bottom-right."""
    img = Image.new('RGBA', (size, size))
    pixels = img.load()
    
    r1, g1, b1 = color1
    r2, g2, b2 = color2
    
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size - 2) if size > 1 else 0
            r = int(r1 + (r2 - r1) * t)
            g = int(g1 + (g2 - g1) * t)
            b = int(b1 + (b2 - b1) * t)
            pixels[x, y] = (r, g, b, 255)
    
    return img


def draw_speech_bubble(draw, cx, cy, w, h, radius, tail_size, fill):
    """Draw a speech bubble with a tail at bottom-left."""
    x1 = cx - w // 2
    y1 = cy - h // 2
    x2 = cx + w // 2
    y2 = cy + h // 2
    
    draw.rounded_rectangle((x1, y1, x2, y2), radius=radius, fill=fill)
    
    # Tail at bottom-left - smooth curved tail
    tail_x = x1 + w * 0.25
    tail_y = y2
    tail_points = [
        (tail_x - tail_size * 0.15, tail_y - tail_size * 0.2),
        (tail_x - tail_size * 1.0, tail_y + tail_size * 0.9),
        (tail_x + tail_size * 0.55, tail_y - tail_size * 0.05),
    ]
    draw.polygon(tail_points, fill=fill)


def draw_bold_M(draw, cx, cy, eff_size):
    """Draw a bold stylized M letter."""
    # M color: blend of gradient colors for harmony
    m_color = (90, 118, 220, 255)
    
    m_w = int(eff_size * 0.28)
    m_h = int(eff_size * 0.25)
    stroke = max(int(eff_size * 0.042), 2)
    
    left = cx - m_w // 2
    right = cx + m_w // 2
    top = cy - m_h // 2
    bottom = cy + m_h // 2
    mid_x = cx
    valley_y = top + int(m_h * 0.6)
    
    # Left vertical leg
    draw.rectangle([left, top, left + stroke, bottom], fill=m_color)
    
    # Right vertical leg
    draw.rectangle([right - stroke, top, right, bottom], fill=m_color)
    
    # Left diagonal - from top-left going down to center valley
    half_s = stroke * 0.7
    draw.polygon([
        (left, top),
        (left + stroke * 1.5, top),
        (mid_x + half_s, valley_y),
        (mid_x - half_s, valley_y),
    ], fill=m_color)
    
    # Right diagonal - from top-right going down to center valley
    draw.polygon([
        (right - stroke * 1.5, top),
        (right, top),
        (mid_x + half_s, valley_y),
        (mid_x - half_s, valley_y),
    ], fill=m_color)
    
    # Serifs / caps at the top for a bolder look
    serif = int(stroke * 0.4)
    draw.rectangle([left - serif, top, left + stroke + serif, top + stroke], fill=m_color)
    draw.rectangle([right - stroke - serif, top, right + serif, top + stroke], fill=m_color)
    
    # Small feet at bottom
    draw.rectangle([left - serif, bottom - stroke, left + stroke + serif, bottom], fill=m_color)
    draw.rectangle([right - stroke - serif, bottom - stroke, right + serif, bottom], fill=m_color)


def create_mellon_icon(size=1024, padding_factor=0.0):
    """Create the Mellon Chat icon."""
    img = create_gradient(size, (74, 144, 217), (123, 104, 238))
    draw = ImageDraw.Draw(img)
    
    pad = int(size * padding_factor)
    eff_size = size - 2 * pad
    cx = size // 2
    cy = size // 2
    
    # Speech bubble
    bubble_w = int(eff_size * 0.60)
    bubble_h = int(eff_size * 0.44)
    bubble_radius = int(eff_size * 0.07)
    tail_size = int(eff_size * 0.13)
    
    bubble_cy = cy - int(eff_size * 0.035)
    
    # Draw soft shadow
    shadow_offset = int(eff_size * 0.012)
    shadow_color = (0, 0, 0, 40)
    draw_speech_bubble(draw, cx + shadow_offset, bubble_cy + shadow_offset * 2,
                       bubble_w, bubble_h, bubble_radius, tail_size, shadow_color)
    
    # Draw main bubble
    draw_speech_bubble(draw, cx, bubble_cy, bubble_w, bubble_h, bubble_radius, tail_size,
                       fill=(255, 255, 255, 245))
    
    # Draw the M
    draw_bold_M(draw, cx, bubble_cy - int(eff_size * 0.01), eff_size)
    
    return img


def create_adaptive_foreground(size=1024):
    """Create adaptive icon foreground with extra padding."""
    return create_mellon_icon(size, padding_factor=0.20)


def main():
    base_dir = "/Users/xavier/mellon-chat"
    
    # Generate master 1024x1024
    print("Generating master 1024x1024 icon...")
    master = create_mellon_icon(1024)
    master_path = os.path.join(base_dir, "assets", "mellon_icon_1024.png")
    os.makedirs(os.path.dirname(master_path), exist_ok=True)
    master.save(master_path, "PNG")
    print(f"  Saved: {master_path}")
    
    # iOS icons
    ios_dir = os.path.join(base_dir, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(ios_dir, exist_ok=True)
    
    ios_icons = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    
    print("\nGenerating iOS icons...")
    for name, px_size in ios_icons.items():
        resized = master.resize((px_size, px_size), Image.Resampling.LANCZOS)
        path = os.path.join(ios_dir, name)
        resized.save(path, "PNG")
        print(f"  {name} ({px_size}x{px_size})")
    
    # Android icons
    android_res = os.path.join(base_dir, "android", "app", "src", "main", "res")
    
    android_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    
    print("\nGenerating Android launcher icons...")
    for folder, px_size in android_sizes.items():
        dir_path = os.path.join(android_res, folder)
        os.makedirs(dir_path, exist_ok=True)
        resized = master.resize((px_size, px_size), Image.Resampling.LANCZOS)
        path = os.path.join(dir_path, "ic_launcher.png")
        resized.save(path, "PNG")
        print(f"  {folder}/ic_launcher.png ({px_size}x{px_size})")
    
    # Save 512x512 at xxxhdpi as requested
    xxxhdpi_dir = os.path.join(android_res, "mipmap-xxxhdpi")
    resized_512 = master.resize((512, 512), Image.Resampling.LANCZOS)
    resized_512.save(os.path.join(xxxhdpi_dir, "ic_launcher.png"), "PNG")
    print(f"  mipmap-xxxhdpi/ic_launcher.png overwritten with 512x512")
    
    # Adaptive icon foreground layers
    print("\nGenerating Android adaptive icon foregrounds...")
    adaptive = create_adaptive_foreground(1024)
    
    for folder, px_size in android_sizes.items():
        dir_path = os.path.join(android_res, folder)
        os.makedirs(dir_path, exist_ok=True)
        fg_size = px_size
        if folder == "mipmap-xxxhdpi":
            fg_size = 512
        resized = adaptive.resize((fg_size, fg_size), Image.Resampling.LANCZOS)
        path = os.path.join(dir_path, "ic_launcher_foreground.png")
        resized.save(path, "PNG")
        print(f"  {folder}/ic_launcher_foreground.png ({fg_size}x{fg_size})")
    
    print("\nAll icons generated successfully!")
    print(f"\nMaster icon: {master_path}")
    print(f"iOS icons:   {ios_dir}/")
    print(f"Android icons: {android_res}/mipmap-*/")


if __name__ == "__main__":
    main()
