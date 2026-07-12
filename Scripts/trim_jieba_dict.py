#!/usr/bin/env python3
"""Trim cppjieba-format dictionary files by frequency threshold.

Line format (jieba.dict.utf8)::
    word freq [tag]

Example::
    python3 Scripts/trim_jieba_dict.py \\
        --input Sources/JiebaFTS5/Resources/jieba.dict.utf8 \\
        --output /tmp/jieba.dict.min5.utf8 \\
        --min-freq 5

Then point the engine at the trimmed file (and keep hmm + user dict)::
    JiebaEngine.configure(dictPath:..., hmmPath:..., userDictPath:...)
    // or register a named engine with JiebaEngine.make(...)

Does not modify in-tree Resources/ by default — safe for package consumers.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", "-i", type=Path, required=True, help="Source jieba.dict.utf8")
    p.add_argument("--output", "-o", type=Path, required=True, help="Trimmed dict path")
    p.add_argument(
        "--min-freq",
        type=int,
        default=5,
        help="Keep lines whose frequency column is >= this value (default: 5)",
    )
    p.add_argument(
        "--keep-missing-freq",
        action="store_true",
        help="Keep lines that have no frequency column (default: drop them)",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    if not args.input.is_file():
        print(f"error: input not found: {args.input}", file=sys.stderr)
        return 1

    kept = 0
    dropped = 0
    out_lines: list[str] = []

    with args.input.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            raw = line.rstrip("\n")
            if not raw.strip() or raw.lstrip().startswith("#"):
                out_lines.append(raw)
                continue
            parts = raw.split()
            if len(parts) < 2:
                if args.keep_missing_freq:
                    out_lines.append(raw)
                    kept += 1
                else:
                    dropped += 1
                continue
            try:
                freq = int(parts[1])
            except ValueError:
                if args.keep_missing_freq:
                    out_lines.append(raw)
                    kept += 1
                else:
                    dropped += 1
                continue
            if freq >= args.min_freq:
                out_lines.append(raw)
                kept += 1
            else:
                dropped += 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(out_lines) + ("\n" if out_lines else ""), encoding="utf-8")

    in_size = args.input.stat().st_size
    out_size = args.output.stat().st_size
    print(f"kept={kept} dropped={dropped}")
    print(f"input_bytes={in_size} output_bytes={out_size} ratio={out_size / max(in_size, 1):.3f}")
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
