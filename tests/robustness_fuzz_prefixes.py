import random
import subprocess
import textwrap

CORPUS = [
    'if 1 [print "ok"]',
    'unless false [print "ok"]',
    'while [i < 3] [i: i + 1]',
    'switch 1 -> print "one" -> print "other"',
    'f: function [x y] [x + y]',
    'g: generator [n] [loop 1..n \'i [yield i]]',
    'it: to :iterator 1..10',
    'mapped: it | map.iterator => [inc &]',
    'filtered: to :iterator 1..10 | filter.iterator \'x [odd? x]',
    'selected: to :iterator 1..10 | select.iterator \'x [even? x]',
    'chunks: read.buffer:4.seek:8 "data.txt"',
    'write.buffer:2.seek:4 ["XY" "ZZ"] "patch.txt"',
    'rows: read.csv.stream.withHeaders "table.csv"',
    'print.lines map.iterator to :iterator 1..3 \'x [x+1]',
    'seek.relative chunks 4',
    'seek.end chunks 2',
]


def run_snippet(binary: str, snippet: str):
    try:
        p = subprocess.run(
            [binary, '--no-color', '-e', snippet],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=4,
        )
        combined = (p.stderr or '') + (p.stdout or '')
        return {
            'timeout': False,
            'returncode': p.returncode,
            'combined': combined,
        }
    except subprocess.TimeoutExpired as e:
        def norm(x):
            if x is None:
                return ''
            if isinstance(x, bytes):
                return x.decode('utf-8', errors='replace')
            return x
        combined = norm(e.stderr) + norm(e.stdout)
        return {
            'timeout': True,
            'returncode': None,
            'combined': combined,
        }


def interesting_prefixes(src: str):
    points = {1, 2, 3, len(src) // 4, len(src) // 2, (3 * len(src)) // 4, len(src) - 1}
    for token in ['[', ']', '(', ')', '->', ':', '.iterator', '.buffer', '.stream']:
        idx = src.find(token)
        if idx >= 0:
            points.add(idx)
            points.add(idx + 1)
    for p in sorted(x for x in points if 0 < x < len(src)):
        yield src[:p]


if __name__ == '__main__':
    random.seed(42)
    binary = './bin/arturo'
    failures = []
    total = 0

    for base in CORPUS:
        variants = set(interesting_prefixes(base))
        # also sample a couple of random internal cuts
        for _ in range(5):
            cut = random.randint(1, max(1, len(base) - 1))
            variants.add(base[:cut])

        for snippet in sorted(variants):
            total += 1
            res = run_snippet(binary, snippet)
            combined = res['combined']

            bad = False
            reason = ''
            if res['timeout']:
                bad = True
                reason = 'timeout'
            elif res['returncode'] is not None and res['returncode'] < 0:
                bad = True
                reason = f'signal:{res["returncode"]}'
            elif 'SIGSEGV' in combined or 'Illegal storage access' in combined:
                bad = True
                reason = 'segv-marker'
            elif res['returncode'] not in (0, 1, 255) and res['returncode'] is not None:
                # Arturo sometimes uses nonzero app-level exits; keep broad, but reject weird ones.
                if res['returncode'] > 1:
                    bad = True
                    reason = f'unexpected-exit:{res["returncode"]}'
            elif res['returncode'] != 0 and not combined.strip():
                bad = True
                reason = 'empty-error-output'

            print(f'[{total:03d}] {"FAIL" if bad else "OK"} :: {snippet!r}')
            if bad:
                failures.append((snippet, reason, combined[:400]))

    if failures:
        print('\nFAILURES:')
        for snippet, reason, detail in failures:
            print('- snippet:', repr(snippet))
            print('  reason :', reason)
            print('  output :', detail.replace('\n', ' '))
        raise SystemExit(1)

    print(f'\nALL_FUZZ_PREFIX_CASES_OK ({total} cases)')
