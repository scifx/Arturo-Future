import subprocess
from pathlib import Path

CASES = [
    ("if", "Not enough parameters"),
    ("unless", "Not enough parameters"),
    ("while", "Not enough parameters"),
    ("switch", "Not enough parameters"),
    ("if 1", "Not enough parameters"),
    ("unless 1", "Not enough parameters"),
    ("while [1]", "Not enough parameters"),
    ("switch 1", "Not enough parameters"),
    ("[", "missing closing square bracket"),
    ("(", "missing closing parenthesis"),
    ("{", "missing closing curly bracket"),
    ('"', "unterminated quoted string"),
    ("do [", "missing closing square bracket"),
    ("map [1 2 3] [", "missing closing square bracket"),
    ("read.buffer \"nope.txt\"", "expects a positive integer"),
    ("read.buffer:0 \"nope.txt\"", "expects a positive integer"),
    ("write.buffer:0 \"abc\" \"x.txt\"", "expects a positive integer"),
    ("seek 123 4", "Wrong argument"),
    ("tell 123", "Wrong argument"),
    ("seek.relative 123 4", "Wrong argument"),
    ("seek.end 123 4", "Wrong argument"),
    ("read.buffer:4.seek:neg 1 \"x.txt\"", "non-negative integer"),
    ("write.buffer:4.seek:neg 1 \"abc\" \"x.txt\"", "non-negative integer"),
]


def run_case(binary: str, snippet: str, expected: str):
    try:
        p = subprocess.run(
            [binary, "--no-color", "-e", snippet],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"

    combined = (p.stderr or "") + (p.stdout or "")
    ok = (p.returncode != 0) and (expected in combined)
    return ok, combined[:400]


if __name__ == "__main__":
    binary = "./bin/arturo"
    failures = []
    rounds = 10
    case_no = 0
    for round_no in range(1, rounds + 1):
        for snippet, expected in CASES:
            case_no += 1
            ok, detail = run_case(binary, snippet, expected)
            print(f"[r{round_no:02d}:{case_no:03d}] {'OK' if ok else 'FAIL'} :: {snippet}")
            if not ok:
                failures.append((round_no, snippet, expected, detail))

    if failures:
        print("\nFAILURES:")
        for round_no, snippet, expected, detail in failures:
            print(f"- round: {round_no}")
            print("  snippet:", snippet)
            print("  expected:", expected)
            print("  got:", detail.replace("\n", " "))
        raise SystemExit(1)

    print("\nALL_ROBUSTNESS_CASES_OK")
