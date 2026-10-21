"""Sinh bảng tên môn GloryFit/UTE cho Kotlin và Swift từ sdks/gloryfit/catalog/sports.tsv.

Dùng (từ gốc repo): python3 -I tools/gen_sport_catalog.py
Ra: sdks/gloryfit/android/src/main/java/com/smartwear/gloryfit/UteSportCatalog.kt
    sdks/gloryfit/ios/Sources/SmartWearGloryFit/UteSportCatalog.swift
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'sdks/gloryfit/catalog/sports.tsv')
KT = os.path.join(ROOT, 'sdks/gloryfit/android/src/main/java/com/smartwear/gloryfit/UteSportCatalog.kt')
SWIFT = os.path.join(ROOT, 'sdks/gloryfit/ios/Sources/SmartWearGloryFit/UteSportCatalog.swift')
HEADER = 'Sinh từ sdks/gloryfit/catalog/sports.tsv bởi tools/gen_sport_catalog.py. Đừng sửa tay.'


def load():
    rows = []
    for line in open(SRC, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line or line.startswith('#') or line.startswith('id\t'):
            continue
        sid, en, vi = line.split('\t')
        rows.append((int(sid), en.strip(), vi.strip()))
    ids = [r[0] for r in rows]
    if len(ids) != len(set(ids)) or any(not en or not vi for _, en, vi in rows):
        sys.exit('sports.tsv: mã trùng hoặc thiếu tên')
    return sorted(rows)


def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    rows = load()
    kt = [f'// {HEADER}', 'package com.smartwear.gloryfit', '',
          f'/** Danh mục {len(rows)} môn của SDK UTE (`SportsMode`): mã → (tiếng Việt, tiếng Anh). Tên tiếng Anh theo GloryFitPro. */',
          'internal object UteSportCatalog {', '    val NAMES: Map<Int, Pair<String, String>> = mapOf(']
    kt += [f'        {i} to ({q(vi)} to {q(en)}),' for i, en, vi in rows]
    kt += ['    )', '}', '']
    sw = [f'// {HEADER}', '',
          f'/// Danh mục {len(rows)} môn của SDK UTE (`SportsMode`): mã → (tiếng Việt, tiếng Anh). Tên tiếng Anh theo GloryFitPro.',
          'enum UteSportCatalog {', '    static let names: [Int: (vi: String, en: String)] = [']
    sw += [f'        {i}: ({q(vi)}, {q(en)}),' for i, en, vi in rows]
    sw += ['    ]', '}', '']
    open(KT, 'w', encoding='utf-8').write('\n'.join(kt))
    open(SWIFT, 'w', encoding='utf-8').write('\n'.join(sw))
    print(f'{len(rows)} môn → {os.path.relpath(KT, ROOT)}, {os.path.relpath(SWIFT, ROOT)}')


if __name__ == '__main__':
    main()
