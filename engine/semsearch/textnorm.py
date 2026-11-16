"""Keyword-side text normalisation: Snowball Finnish stems appended to the indexed text.
Query tokens go through the same function, so inflections meet at the stem."""
import os
import re
from functools import lru_cache

import snowballstemmer

_STEM = snowballstemmer.stemmer("finnish")
TOKEN = re.compile(r"[^\W_]+")  # letters and digits: an underscore separates words (poliittinen_meta_kartta)


@lru_cache(maxsize=200_000)
def stem(word: str) -> str:
    return _STEM.stemWord(word)


def tokens(text: str) -> list:
    return TOKEN.findall(text.lower())


def keyword_text(text: str, cfg) -> str:
    if not cfg.get("stemming"):
        return text
    return text + "\n" + " ".join(stem(t) for t in tokens(text))


def name_text(path: str, cfg) -> str:
    """The file name without its extension, as keyword text: "IMG_1723.jpg" -> "IMG_1723"."""
    return keyword_text(os.path.splitext(os.path.basename(path))[0], cfg)
