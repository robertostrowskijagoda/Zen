"""Sums up the line coverage of the app's tests (lcov files of the runs of
tool/test.dart --coverage, one folder or several) for CI's job summary:
the total, the files of lib/ that no test touches at all, and the least
covered of the bigger files. Plain Python, no packages.

  python tool/ci/coverage_report.py <folder>... [--summary FILE] [--min PERCENT]

--summary appends Markdown to FILE ($GITHUB_STEP_SUMMARY in CI). --min
fails (exit 1) when the total falls below PERCENT; without it the report
only informs. Files under lib/src/dev/ and generated files are left out.
"""

import argparse
import glob
import os
import sys

SKIPPED_PREFIXES = ('lib/src/dev/',)
SKIPPED_SUFFIXES = ('.g.dart', '.freezed.dart')


def normal(path):
    path = path.replace('\\', '/')
    index = path.find('lib/')
    return path[index:] if index >= 0 else path


def counted(path):
    return (
        path.startswith('lib/')
        and path.endswith('.dart')
        and not path.startswith(SKIPPED_PREFIXES)
        and not path.endswith(SKIPPED_SUFFIXES)
    )


def read_lcov(paths):
    """{file: {line: hits}}, the hits of every run added up."""
    lines = {}
    for path in paths:
        current = None
        with open(path, encoding='utf-8', errors='replace') as f:
            for raw in f:
                raw = raw.strip()
                if raw.startswith('SF:'):
                    current = normal(raw[3:])
                    lines.setdefault(current, {})
                elif raw.startswith('DA:') and current is not None:
                    number, hits = raw[3:].split(',')[:2]
                    seen = lines[current]
                    seen[int(number)] = seen.get(int(number), 0) + int(hits)
                elif raw == 'end_of_record':
                    current = None
    return lines


def all_lib_files(root):
    out = []
    for path in glob.glob(os.path.join(root, 'lib', '**', '*.dart'), recursive=True):
        rel = os.path.relpath(path, root).replace('\\', '/')
        if counted(rel):
            out.append(rel)
    return sorted(out)


def report(folders, root='.'):
    paths = []
    for folder in folders:
        paths += glob.glob(os.path.join(folder, '**', '*.info'), recursive=True)
    lines = read_lcov(paths)
    files = {f: l for f, l in lines.items() if counted(f)}
    total = sum(len(l) for l in files.values())
    hit = sum(1 for l in files.values() for h in l.values() if h > 0)
    untouched = [f for f in all_lib_files(root) if f not in files]
    ranked = sorted(
        (
            (sum(1 for h in l.values() if h > 0) / len(l), f, len(l))
            for f, l in files.items()
            if len(l) >= 80
        ),
    )
    return {
        'runs': len(paths),
        'percent': 100.0 * hit / total if total else 0.0,
        'lines': total,
        'hit': hit,
        'untouched': untouched,
        'lowest': ranked[:15],
    }


def markdown(result):
    out = [
        '### Test coverage',
        '',
        '%.1f%% of %d lines of lib/ (%d runs).' % (
            result['percent'], result['lines'], result['runs']),
        '',
    ]
    if result['untouched']:
        out.append('Files no test loads at all (%d):' % len(result['untouched']))
        out.append('')
        for f in result['untouched'][:40]:
            out.append('- `%s`' % f)
        if len(result['untouched']) > 40:
            out.append('- … and %d more' % (len(result['untouched']) - 40))
        out.append('')
    if result['lowest']:
        out.append('Least covered of the files of 80 lines or more:')
        out.append('')
        out.append('| File | Covered | Lines |')
        out.append('|---|---|---|')
        for share, f, n in result['lowest']:
            out.append('| `%s` | %.0f%% | %d |' % (f, 100 * share, n))
        out.append('')
    return '\n'.join(out) + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('folders', nargs='+')
    parser.add_argument('--summary')
    parser.add_argument('--min', type=float)
    parser.add_argument('--root', default='.')
    args = parser.parse_args(argv)
    result = report(args.folders, args.root)
    text = markdown(result)
    print(text)
    if args.summary:
        with open(args.summary, 'a', encoding='utf-8') as f:
            f.write(text)
    if result['runs'] == 0:
        print('::warning::No coverage files found.')
        return 0
    if args.min is not None and result['percent'] < args.min:
        print('::error::Coverage %.1f%% is below %.1f%%.' % (result['percent'], args.min))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
