#!/usr/bin/env python3
"""Leave-one-out evaluation of the recogniser against a real library.

Run this as the library grows. Every parameter in recognise.py that could have
been guessed at was instead settled here, and two of them reversed themselves
when the library got bigger -- so re-running this is the method rather than a
formality.

Scoring must mirror cmd_match exactly. An evaluator that measures something the
tool does not do reports a number nobody will ever see.

    .venv/bin/python tools/recognise/evaluate.py --refs .../.reapertoire-references.json
"""

import argparse
import itertools
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import recognise as R


def rank(probe, songs):
    out = []
    for song, refs in songs.items():
        if not refs:
            continue
        # The mean of the two closest takes, exactly as cmd_match scores.
        closest = sorted(R.distance(probe, r) for r in refs)
        out.append((song, 1.0 - float(np.mean(closest[:2]))))
    out.sort(key=lambda x: -x[1])
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--refs", required=True)
    parser.add_argument("--margin", type=float, default=0.10)
    args = parser.parse_args()

    library = json.loads(Path(args.refs).expanduser().read_text())["songs"]

    print("Feature separation -- a feature is useful when same-song gaps are")
    print("smaller than different-song gaps.\n")
    # Duration is not scored, but it is measured here anyway: seeing its
    # separation go negative is what settled the argument for removing it, and
    # a future library might not behave the same way.
    KEYS = ("chroma", "duration")
    same, diff = {k: [] for k in KEYS}, {k: [] for k in KEYS}
    def gaps(a, b, into):
        into["chroma"].append(float(np.linalg.norm(np.array(a["chroma"]) - np.array(b["chroma"]))))
        into["duration"].append(abs(a["duration"] - b["duration"]))
    for refs in library.values():
        for a, b in itertools.combinations(refs, 2):
            gaps(a, b, same)
    for (_, r1), (_, r2) in itertools.combinations(library.items(), 2):
        for a in r1:
            for b in r2:
                gaps(a, b, diff)

    print("  feature    same-song   different-song   separation")
    for key in KEYS:
        s, d = np.array(same[key]), np.array(diff[key])
        if not len(s) or not len(d):
            continue
        sep = (d.mean() - s.mean()) / d.std() if d.std() else 0.0
        print(f"  {key:10s} {s.mean():9.2f} {d.mean():16.2f} {sep:12.2f}")

    print("\nLeave-one-out over takes whose song has another reference:\n")
    t1 = t3 = n = shown = shown_right = 0
    for song, refs in library.items():
        if len(refs) < 2:
            continue
        for i, held in enumerate(refs):
            reduced = {
                s: [r for j, r in enumerate(v) if not (s == song and j == i)]
                for s, v in library.items()
            }
            reduced = {s: v for s, v in reduced.items() if v}
            ranked = rank(held, reduced)
            names = [s for s, _ in ranked]
            n += 1
            hit = names[0] == song
            t1 += hit
            t3 += song in names[:3]
            # The same relative margin the panel uses: the lead over the
            # runner-up as a fraction of it, not an absolute gap.
            confident = False
            if len(ranked) > 1:
                first, second = 1.0 - ranked[0][1], 1.0 - ranked[1][1]
                confident = second > 0 and (second - first) / second >= args.margin
            if confident:
                shown += 1
                shown_right += hit
            mark = "OK  " if hit else ("top3" if song in names[:3] else "MISS")
            top = ", ".join(f"{s} {v:.2f}" for s, v in ranked[:3])
            print(f"  {mark} {'*' if confident else ' '} {song:<16} -> {top}")

    if n:
        print(f"\n  top-1 {t1}/{n} ({100*t1/n:.0f}%)   top-3 {t3}/{n} ({100*t3/n:.0f}%)")
        print(f"  pre-selected (relative margin >= {args.margin}): {shown}, "
              f"of which correct {shown_right}")
        print("\n  A small sample: differences of one or two here are noise.")


if __name__ == "__main__":
    main()
