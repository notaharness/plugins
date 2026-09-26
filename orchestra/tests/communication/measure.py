"""Measure saved style samples; no model calls or external dependencies.

Run: python3 orchestra/tests/communication/measure.py
Widths include raw Markdown syntax. This is a hard-wrap approximation, not a
Claude/Codex renderer or a measure of human comprehension. Fixture characters
use Unicode east-Asian width; combining marks take no column.
"""
import json
import re
import unicodedata
from pathlib import Path


def columns(text):
    return sum(0 if unicodedata.combining(c) else
               2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1
               for c in text)


def rows(line, width):
    return max(1, (columns(line) + width - 1) // width)


def measure(text):
    lines = text.splitlines()
    prose = [p for p in re.split(r'\n\s*\n', text)
             if p and not re.match(r'^(?:#{1,6} |[-*] |\||---)', p)]
    decision = next((i for i, line in enumerate(lines)
                     if re.search(r'\bDecision:', line, re.I)), None)
    tables = [columns(line) for line in lines if line.startswith('|')]
    return {
        'words': len(text.split()),
        'rows80': sum(rows(line, 80) for line in lines),
        'rows120': sum(rows(line, 120) for line in lines),
        'decision80': sum(rows(line, 80) for line in lines[:decision]) + 1
                      if decision is not None else None,
        'largest_block_words': max((len(p.split()) for p in prose), default=0),
        'widest_table_row': max(tables, default=0),
    }


if __name__ == '__main__':
    samples = json.loads(Path(__file__).with_name('samples.json').read_text())
    print('| Style | Case | Words | Rows 80 / 120 | Decision row 80 | Largest prose block | Widest table row |')
    print('| --- | --- | ---: | ---: | ---: | ---: | ---: |')
    for style, sample in samples.items():
        for case, text in sample['replies'].items():
            m = measure(text)
            print(f"| {style} | {case} | {m['words']} | {m['rows80']} / {m['rows120']} | "
                  f"{m['decision80'] or '—'} | {m['largest_block_words']} | {m['widest_table_row']} |")
