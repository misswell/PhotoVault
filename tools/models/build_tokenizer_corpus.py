"""Build an adversarial corpus for tokenizer parity testing.

The corpus is deliberately hostile: it must break a tokenizer that mishandles
non-ASCII, byte fallback, user-defined pieces, or whitespace. Real search
queries are a small subset of what is covered here.
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

# Queries a user would plausibly type, in both languages.
REAL_QUERIES = [
    # Chinese — the primary use case
    "海边的狗", "发票", "报销凭证", "猫", "生日蛋糕", "雪山日出", "儿子的照片",
    "去年夏天在海边拍的照片", "白色衬衫", "红色的花", "夜景", "美食", "咖啡拉花",
    "文档扫描件", "身份证", "银行卡", "机票", "登机牌", "高铁票", "酒店",
    "会议室白板", "手写笔记", "长截图", "微信聊天记录", "二维码", "车牌",
    "婚礼", "毕业照", "全家福", "婴儿", "宠物狗", "橘猫", "落日", "星空",
    "烟花", "雪景", "秋天的落叶", "雨中街道", "地铁站", "机场", "书店",
    "咖啡店", "菜单", "购物小票", "合同", "简历", "PPT 截图", "代码截图",
    "报错信息", "表格", "图表", "折线图", "柱状图", "饼图", "地图定位",
    "带 GPS 的照片", "2023 年的照片", "上个月拍的照片", "风景照", "美食照片",
    "没有人的照片", "有猫有狗的照片", "海边但不是日落的照片", "模糊的照片",
    "夜景照片", "自拍", "合影", "证件照", "扫描的文档", "收据照片",
    # English
    "dog on the beach", "invoice", "receipt", "cat", "birthday cake",
    "snowy mountain sunrise", "photo of my son", "white shirt",
    "red flowers", "night scene", "food", "latte art", "scanned document",
    "boarding pass", "whiteboard", "handwritten notes", "long screenshot",
    "QR code", "license plate", "wedding", "graduation", "family portrait",
    "sunset", "starry sky", "fireworks", "autumn leaves", "street in rain",
    "subway station", "airport", "bookstore", "cafe", "menu", "shopping receipt",
    "contract", "resume", "screenshot of code", "error message", "spreadsheet",
    "chart", "line graph", "bar chart", "pie chart", "map location",
    "photo with GPS", "photos from 2023", "photos from last month",
    "landscape", "food photo", "photos without people", "photos with a cat and a dog",
    "beach but not sunset", "blurry photos", "selfie", "group photo", "ID photo",
    # Mixed / punctuation / spacing
    "海边 beach", "发票 invoice", "2023年 夏天", "iPhone 拍的照片",
    "HEIC 格式", "IMG_1234", "a   b", "  leading", "trailing  ",
    "no-spaces-here", "under_score", "CamelCaseWord", "UPPERCASE",
    "MiXeD CaSe", "digits 0123456789", "year 2023-05-01", "time 12:34:56",
    "percent 50%", "price $19.99", "email a@b.com", "url https://example.com/path?q=1",
    "emoji \U0001f600\U0001f44d", "flag \U0001f1e8\U0001f1f3", "zwj \U0001f469\u200d\U0001f4bb",
    "full-width\uff21\uff22\uff23", "half-width ABC",
    "full-width punct\uff0c\u3002\uff01\uff1f", "cjk punct \u3001\u300a\u300b\u201c\u201d",
    "combining e\u0301", "accented caf\u00e9", "cyrillic \u043f\u0440\u0438\u0432\u0435\u0442",
    "greek \u03b1\u03b2\u03b3", "arabic \u0645\u0631\u062d\u0628\u0627", "hebrew \u05e9\u05dc\u05d5\u05dd",
    "thai \u0e2a\u0e27\u0e31\u0e2a\u0e14\u0e35", "korean \uc548\ub155\ud558\uc138\uc694",
    "japanese \u3053\u3093\u306b\u3061\u306f", "hiragana \u3042\u3044\u3046",
    "kanji \u6f22\u5b57", "hangul \ud55c\uae00",
]

# Structural edge cases aimed at the pieces that are USER_DEFINED in this
# checkpoint: the prefix matcher splits on these and freezes them.
STRUCTURAL = [
    "", " ", "  ", "   ", "\t", "\n", "\r\n", "\n\n", "\n\n\n\n\n\n\n\n",
    "\u2581", "\u2581\u2581", "\u2581\u2581\u2581\u2581", "\u2581abc",
    "<start_of_turn>", "<end_of_turn>", "<mask>", "<2mass>", "[@BOS@]",
    "<unused0>", "<unused99>", "<table>", "</table>", "<td>", "<h1>", "</b>",
    "[toxicity=0]", "<pad>", "<eos>", "<bos>", "<unk>",
    "a<start_of_turn>b", "<table>cell</table>", "a\n\n\n\nb",
    "text with <table> tag", "a<unused5>b", "<<unused0>>",
    "<", ">", "<x>", "<0x41>", "0x41",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "a" * 300, "\u6d77" * 300, "\U0001f600" * 200,
    "the quick brown fox jumps over the lazy dog " * 30,
    " " * 65, "\n" * 70,
    # lone surrogates aren't valid Python str in a JSON round-trip safe way, so
    # use raw high code points and NUL instead
    "\x00", "a\x00b", "\x01\x02\x03", "\x7f", "\u0080", "\u00ff", "\uffff",
    "\ue000", "\U0001f4a9", "\U0010ffff",
]

# Long realistic strings, to exercise >64-token truncation.
LONG = [
    "我想找一张去年夏天在海边拍的、有狗但是没有日落的照片，最好是白天拍的，不要模糊的",
    "a photo of my dog at the beach during the summer of last year, not at sunset, "
    "during the daytime, and please exclude anything blurry or taken at night",
    "帮我找 2023 年 5 月在东京拍的所有带 GPS 的照片，不要自拍，也不要合影",
    "发票 报销 凭证 收据 合同 简历 登机牌 高铁票 酒店 会议室 白板 笔记 截图 二维码 车牌",
]

# Fuzz: random byte-ish strings, ensuring invalid UTF-8 sequences still round
# trip through surrogateescape.
FUZZ_ALPHABET = (
    "abcXYZ019 \u2581\n\t<>=/[]{}()\u6d77\u4e2d\u6587\U0001f600\uff21\u00e9\u043f"
)


def build(seed: int = 20260913) -> list[str]:
    rng = random.Random(seed)
    texts: list[str] = []
    for group in (REAL_QUERIES, STRUCTURAL, LONG):
        texts.extend(group)
    # Random short strings: the highest-yield source of odd cases.
    for _ in range(3000):
        n = rng.randint(1, 60)
        texts.append("".join(rng.choice(FUZZ_ALPHABET) for _ in range(n)))
    # Random wide code points: valid UTF-8, but mostly absent from the vocab, so
    # this is what actually drives the byte-fallback path. Surrogates are
    # excluded because they cannot occur in a Swift String, and the app never
    # tokenizes invalid UTF-8.
    def rand_code_point() -> str:
        while True:
            cp = rng.randrange(0x110000)
            if not 0xD800 <= cp <= 0xDFFF:
                return chr(cp)

    for _ in range(2000):
        n = rng.randint(1, 30)
        texts.append("".join(rand_code_point() for _ in range(n)))
    # Mixed: known text salted with rare code points.
    for _ in range(1000):
        n = rng.randint(1, 12)
        base = rng.choice(REAL_QUERIES)
        salt = "".join(rand_code_point() for _ in range(n))
        pos = rng.randint(0, len(base))
        texts.append(base[:pos] + salt + base[pos:])
    # Deduplicate while preserving order.
    seen: set[str] = set()
    out: list[str] = []
    for t in texts:
        if t not in seen:
            seen.add(t)
            out.append(t)
    return out


def main() -> int:
    out = Path(__file__).parent / "build" / "tokenizer-corpus.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    texts = build()
    out.write_text(json.dumps({"texts": texts}, ensure_ascii=False))
    print(f"wrote {len(texts)} strings to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
