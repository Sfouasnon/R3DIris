# sphereclue — offline clue analysis for the sphere solver

An offline harness for `R3DIris/Analysis/SphereDetector.swift`. It ports the Swift gate math to
Python and runs it as **clues** — every channel reports its value *and* how much that value moves
under small geometry error — so detector changes can be measured against real bench frames before
they ship. Ground-truth ROIs are derived independently of the detector (luma threshold → largest
blob → trimmed Kåsa boundary fit), so the limb refinement can be scored against something other
than itself.

Findings from the first run are in `../../SPHERE_CLUE_FINDINGS.md`.

    pip install -r requirements.txt

    # single frame, rough ROI, auto-snapped; --at adds a downscaled buffer
    python3 clue_ledger.py FRAME.png --roi CX CY R --at 480 --json out.json

    # locate the sphere in every frame of a directory (no detector involvement)
    python3 find_spheres.py          # writes data/spheres.json + verify crops

    # clue ledger + gate outcomes + conditioning table over the whole corpus
    python3 aggregate.py             # writes data/ledger_all.json

    # harvest flat achromatic cards as negatives, test circularity+convexity
    python3 negatives.py             # writes data/pos_neg.json

`find_spheres.py`, `aggregate.py` and `negatives.py` carry hard-coded input globs from the session
that produced them — point them at your own frame directory before re-running. `clue_ledger.py` is
the reusable piece and takes its frame and ROI on the command line.

## data/

- `spheres.json` — 13 ground-truth sphere ROIs from the 2026-08-12 KOMODO-X bench frames
- `ledger_all.json` — full per-frame clue ledger and conditioning
- `pos_neg.json` — 13 positives and 6 negatives (gray/white cards, monitor panels) with the
  circularity and convexity clues

These double as regression fixtures: the numbers quoted in `SPHERE_CLUE_FINDINGS.md` and in the
`SphereDetector.swift` header comments were produced from them.
