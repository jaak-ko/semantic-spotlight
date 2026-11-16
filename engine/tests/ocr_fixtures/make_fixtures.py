"""Regenerates the OCR test images and their ground truth (deterministic). Run: python make_fixtures.py"""
import json
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).parent
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"

PAGES = {
    "en_screenshot.png": [
        "Quarterly sales report",
        "Northern region revenue grew 12 percent in March.",
        "Send the final numbers to the finance team by Friday.",
    ],
    "fi_resepti.png": [
        "Kardemummapullan resepti",
        "500 g vehnäjauhoja, 5 dl maitoa, 100 g voita",
        "Kohota taikina kaksi tuntia lämpimässä.",
        "Paista 225 asteessa, äidin ohje öljyn kanssa.",
    ],
}


def text_image(lines, size=34):
    font = ImageFont.truetype(FONT, size)
    img = Image.new("RGB", (1100, 60 + 70 * len(lines)), "white")
    draw = ImageDraw.Draw(img)
    for i, line in enumerate(lines):
        draw.text((40, 30 + 70 * i), line, fill="black", font=font)
    return img


def photo_of_page(lines):
    """A harder case: small text, rotated, blurred, JPEG-compressed, like a hand-held phone photo."""
    img = text_image(lines, size=24).convert("L")
    img = img.rotate(1.5, expand=True, fillcolor=235).filter(ImageFilter.GaussianBlur(0.8))
    return img.convert("RGB")


def photo_without_text():
    rnd = random.Random(7)  # fixed seed: the same bytes every run
    w, h = 480, 320
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            n = rnd.randint(-10, 10)
            px[x, y] = (x * 255 // w + n, y * 255 // h + n, 140 + n)
    return img


if __name__ == "__main__":
    truth = {}
    for name, lines in PAGES.items():
        text_image(lines).save(HERE / name)
        truth[name] = "\n".join(lines)
    photo_of_page(PAGES["fi_resepti.png"]).save(HERE / "fi_photo.jpg", quality=50)
    truth["fi_photo.jpg"] = "\n".join(PAGES["fi_resepti.png"])
    photo_without_text().save(HERE / "photo_no_text.jpg", quality=80)
    truth["photo_no_text.jpg"] = ""
    (HERE / "ground_truth.json").write_text(json.dumps(truth, ensure_ascii=False, indent=1))
    print("wrote", ", ".join(sorted(truth)))
