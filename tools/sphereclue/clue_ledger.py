#!/usr/bin/env python3
"""
clue_ledger.py — offline clue ledger for the R3DIris sphere solver.

Faithful Python port of SphereDetector.swift's gate math, run as CLUES rather
than gates: every channel reports its value, and the harness also reports how
much that value MOVES under small geometry error — which is the empirical basis
for how much weight the clue should carry.

Ground truth for a frame is obtained independently of the detector (luma
threshold -> largest component -> unweighted Kasa boundary fit), so limb
refinement can be scored against it instead of against itself.

  python3 clue_ledger.py FRAME.png --roi CX CY R        # rough ROI, auto-snapped
  python3 clue_ledger.py FRAME.png --roi CX CY R --json out.json
  python3 clue_ledger.py FRAME.png --roi CX CY R --at 480   # also run at 480px

Thresholds cited from SphereDetector.swift (ported R3DMatch sphere.py values).
"""
import argparse, json, math, sys
import numpy as np
from PIL import Image
from scipy import ndimage

# ---- ported constants (SphereDetector.swift) --------------------------------
PF_RADIUS_MIN      = 0.018
PF_STD_CLEAN_MAX   = 0.020
PF_STD_HARD_MAX    = 0.130
PF_STD_FLOOR       = 0.008
PF_RG              = (0.90, 1.25)
PF_BG              = (0.80, 1.20)
RADIUS_RATIO       = (0.02, 0.32)
CHROMA_MAX         = 0.045
LAMBERT_TOL        = 0.12
IRE_SPREAD_MIN     = 0.8
STDDEV_GATE        = (0.003, 0.170)
SHADOW_MAX         = 0.96
SHADOW_MAX_PASS2   = 0.985
REFINE_RAYS        = 48
REFINE_MIN_HITS    = 10
REFINE_GRAD_FLOOR  = 0.015
REFINE_MAX_SHIFT   = 0.35

def load(path, maxdim=None):
    im = Image.open(path).convert('RGB')
    s = 1.0
    if maxdim:
        s = min(1.0, maxdim / max(im.size))
        im = im.resize((max(1, round(im.width*s)), max(1, round(im.height*s))), Image.BILINEAR)
    a = np.asarray(im).astype(np.float64) / 255.0
    lum = 0.2126*a[...,0] + 0.7152*a[...,1] + 0.0722*a[...,2]   # BT.709, as ported
    return a, lum, s

def norm_width(w, h):           # SphereDetector.normalizationWidth
    return min(float(w), h * 16.0/9.0)

def _disk(shape, cx, cy, r):
    h, w = shape
    y0, y1 = max(0, int(cy-r)), min(h-1, int(cy+r)+1)
    x0, x1 = max(0, int(cx-r)), min(w-1, int(cx+r)+1)
    if y0 > y1 or x0 > x1: return np.array([],int), np.array([],int)
    ys, xs = np.mgrid[y0:y1+1, x0:x1+1]
    m = (xs-cx)**2 + (ys-cy)**2 <= r*r
    return ys[m], xs[m]

def interior_std(lum, cx, cy, r):
    ys, xs = _disk(lum.shape, cx, cy, r)
    if len(ys) < 20: return 1.0, 0.0
    v = lum[ys, xs]; return float(v.std()), float(v.mean())

def chroma(rgb, cx, cy, r):
    ys, xs = _disk(rgb.shape[:2], cx, cy, r*0.70)
    if len(ys) < 10: return 999.0, 99.0, 99.0
    sr, sg, sb = rgb[ys,xs,0].sum(), rgb[ys,xs,1].sum(), rgb[ys,xs,2].sum()
    t = sr+sg+sb
    return float(math.hypot(sr/t-1/3, sg/t-1/3)), float(sr/sg), float(sb/sg)

def ring_lum(lum, cx, cy, rr, hw):
    h, w = lum.shape; o = rr+hw
    y0,y1 = max(0,int(cy-o)), min(h-1,int(cy+o)+1); x0,x1 = max(0,int(cx-o)), min(w-1,int(cx+o)+1)
    if y0>y1 or x0>x1: return None
    ys,xs = np.mgrid[y0:y1+1, x0:x1+1]; d = np.hypot(xs-cx, ys-cy)
    m = (d >= rr-hw) & (d <= rr+hw)
    return float(lum[ys[m],xs[m]].mean()) if m.sum() >= 4 else None

def lambertian(lum, cx, cy, r):
    rl = [ring_lum(lum, cx, cy, f*r, 0.06*r) for f in (0.20, 0.45, 0.68, 0.80)]
    v = sum(1 for i in range(3)
            if rl[i] is not None and rl[i+1] is not None and rl[i+1] > rl[i]*(1+LAMBERT_TOL))
    return v, rl

def axis_peak_pixel(lum, cx, cy, r):
    """AS SHIPPED: shading axis from the single brightest interior pixel."""
    ys, xs = _disk(lum.shape, cx, cy, r*0.7)
    if len(ys) < 20: return (1.0, 0.0)
    k = int(np.argmax(lum[ys, xs])); dx, dy = xs[k]-cx, ys[k]-cy
    n = math.hypot(dx, dy)
    return (dx/n, dy/n) if n > 1.0 else (1.0, 0.0)

def axis_plane_fit(lum, cx, cy, r):
    """PROPOSED: shading axis from a least-squares plane fit to interior luma."""
    ys, xs = _disk(lum.shape, cx, cy, r*0.7)
    if len(ys) < 20: return (1.0, 0.0), 0.0
    v = lum[ys, xs]
    g = np.linalg.lstsq(np.c_[xs-cx, ys-cy, np.ones(len(v))], v, rcond=None)[0][:2]
    n = math.hypot(*g)
    if n < 1e-12: return (1.0, 0.0), 0.0
    return (g[0]/n, g[1]/n), float(n)

def shadow_ratio(lum, cx, cy, r, axis):
    ys, xs = _disk(lum.shape, cx, cy, r*0.7)
    if len(ys) < 20: return 0.0
    v = lum[ys, xs]; dx, dy = axis
    proj = (xs-cx)*dx + (ys-cy)*dy
    b, d = v[proj >= 0], v[proj < 0]
    if len(b) == 0 or len(d) == 0: return 0.0
    return float(d.mean() / max(b.mean(), 1e-6))

def zone_median(lum, cx, cy, pr):
    ys, xs = _disk(lum.shape, cx, cy, pr)
    if len(ys) == 0: return None
    v = lum[ys, xs]; v = v[v > 0]
    return float(np.median(v)*100) if len(v) >= 4 else None

def ire_spread(lum, cx, cy, r, axis):
    off = max(3.0, 0.30*r); pr = max(2.5, 0.15*r); dx, dy = axis
    b = zone_median(lum, cx+dx*off, cy+dy*off, pr)
    d = zone_median(lum, cx-dx*off, cy-dy*off, pr)
    return abs(b-d) if (b is not None and d is not None) else 0.0

def hero_ire(lum, cx, cy, r):
    ys, xs = _disk(lum.shape, cx, cy, r*0.24)
    if len(ys) == 0: return None
    v = np.sort(lum[ys, xs][lum[ys, xs] > 0])
    if len(v) < 4: return None
    lo = int(len(v)*0.05); hi = max(lo+1, int(len(v)*0.95))
    return float(np.median(v[lo:hi])*100)

def kasa(pts, weighted=True):
    P = np.asarray(pts, float)
    X, Y = P[:,0], P[:,1]
    w = P[:,2] if (weighted and P.shape[1] > 2) else np.ones(len(P))
    Z = X*X + Y*Y
    M = np.array([[(w*X*X).sum(), (w*X*Y).sum(), (w*X).sum()],
                  [(w*X*Y).sum(), (w*Y*Y).sum(), (w*Y).sum()],
                  [(w*X).sum(),   (w*Y).sum(),   w.sum()]])
    rhs = -np.array([(w*X*Z).sum(), (w*Y*Z).sum(), (w*Z).sum()])
    try: D, E, F = np.linalg.solve(M, rhs)
    except np.linalg.LinAlgError: return None
    cx, cy = -D/2, -E/2
    r2 = cx*cx + cy*cy - F
    return (cx, cy, math.sqrt(r2)) if r2 > 0 else None

def refine_to_limb(lum, cx, cy, r, iters=4):
    """Port of SphereDetector.refineToLimb — 1px finite-difference ray search."""
    h, w = lum.shape; pts = []
    for _ in range(iters):
        pts = []; r0, r1 = r*0.55, r*1.45
        for k in range(REFINE_RAYS):
            a = k*2*math.pi/REFINE_RAYS; ux, uy = math.cos(a), math.sin(a)
            best, bt, prev = 0.0, -1.0, None
            t = r0
            while t <= r1:
                x, y = int(round(cx+ux*t)), int(round(cy+uy*t))
                if not (0 <= x < w and 0 <= y < h): break
                v = lum[y, x]
                if prev is not None:
                    m = abs(v-prev)
                    if m > best: best, bt = m, t-0.5
                prev = v; t += 1.0
            if best >= REFINE_GRAD_FLOOR and bt > 0:
                pts.append((cx+ux*bt, cy+uy*bt, best))
        if len(pts) < REFINE_MIN_HITS: break
        fit = kasa(pts)
        if fit is None: break
        res = np.abs(np.hypot(np.array([p[0] for p in pts])-fit[0],
                              np.array([p[1] for p in pts])-fit[1]) - fit[2])
        cut = np.sort(res)[max(0, len(res)*3//4 - 1)]
        kept = [p for p, e in zip(pts, res) if e <= cut]
        if len(kept) >= REFINE_MIN_HITS:
            f2 = kasa(kept)
            if f2 is not None: fit = f2
        ncx, ncy, nr = fit
        if not (r*0.6 <= nr <= r*1.6) or nr < 4: break
        sh = math.hypot(ncx-cx, ncy-cy); mx = r*REFINE_MAX_SHIFT
        if sh > mx:
            s = mx/sh
            cx, cy, r = cx+(ncx-cx)*s, cy+(ncy-cy)*s, r+(nr-r)*s
        else:
            cx, cy, r = ncx, ncy, nr
    arc = len(pts)
    if arc >= REFINE_MIN_HITS:
        res = np.abs(np.hypot(np.array([p[0] for p in pts])-cx,
                              np.array([p[1] for p in pts])-cy) - r)
        rms = float(res.mean()/r)
    else:
        rms = float('nan')
    return cx, cy, r, arc, rms

def ground_truth(lum, cx, cy, r, thresh=0.30, pad=2.0):
    """Detector-independent ROI: luma threshold -> largest blob -> boundary fit."""
    h, w = lum.shape
    x0, y0 = max(0, int(cx-pad*r)), max(0, int(cy-pad*r))
    x1, y1 = min(w, int(cx+pad*r)), min(h, int(cy+pad*r))
    sub = lum[y0:y1, x0:x1]
    m = ndimage.binary_opening(sub > thresh, np.ones((5,5)))
    lab, n = ndimage.label(m)
    if n == 0: return None
    k = int(np.argmax(ndimage.sum(m, lab, range(1, n+1)))) + 1
    blob = lab == k
    edge = blob & ~ndimage.binary_erosion(blob)
    by, bx = np.nonzero(edge)
    fit = kasa(np.c_[bx+x0, by+y0, np.ones(len(bx))], weighted=False)
    if fit is None: return None
    fcx, fcy, fr = fit
    res = np.abs(np.hypot(bx+x0-fcx, by+y0-fcy) - fr)
    r_area = math.sqrt(blob.sum()/math.pi)
    return dict(cx=fcx, cy=fcy, r=fr, boundary_rms_over_r=float(res.mean()/fr),
                circularity=float(r_area/fr))

def ledger(rgb, lum, cx, cy, r):
    w = lum.shape[1]; nw = norm_width(lum.shape[1], lum.shape[0])
    ch, rg, bg = chroma(rgb, cx, cy, r)
    stdf, _ = interior_std(lum, cx, cy, r)
    std85, mean85 = interior_std(lum, cx, cy, r*0.85)
    viol, rl = lambertian(lum, cx, cy, r)
    apk = axis_peak_pixel(lum, cx, cy, r)
    apf, grad = axis_plane_fit(lum, cx, cy, r)
    return {
      'r_over_normW':        r/nw,
      'interiorStd_full_r':  stdf,
      'interiorStd_085r':    std85,
      'interiorStd_over_mean': std85/mean85 if mean85 else None,
      'chroma_dist':         ch, 'rg': rg, 'bg': bg,
      'lambertian_violations': viol, 'rings': rl,
      'heroIRE':             hero_ire(lum, cx, cy, r),
      'shadowRatio_as_shipped':  shadow_ratio(lum, cx, cy, r, apk),
      'shadow_axis_as_shipped_deg': math.degrees(math.atan2(apk[1], apk[0])),
      'shadowRatio_plane_fit':   shadow_ratio(lum, cx, cy, r, apf),
      'shadow_axis_plane_fit_deg': math.degrees(math.atan2(apf[1], apf[0])),
      'shading_gradient_per_px': grad,
      'ireSpread_hardcoded_x': ire_spread(lum, cx, cy, r, (1.0, 0.0)),
      'ireSpread_on_axis':     ire_spread(lum, cx, cy, r, apf),
    }

def conditioning(rgb, lum, cx, cy, r, scales=(0.90,0.95,1.00,1.05,1.10)):
    """How much each clue moves under radius error — the empirical weight basis."""
    keys = ['interiorStd_full_r','interiorStd_085r','chroma_dist','heroIRE',
            'shadowRatio_as_shipped','shadowRatio_plane_fit','ireSpread_hardcoded_x']
    series = {k: [] for k in keys}
    for s in scales:
        L = ledger(rgb, lum, cx, cy, r*s)
        for k in keys: series[k].append(L[k])
    out = {}
    for k, v in series.items():
        base = v[scales.index(1.00)]
        band = [v[i] for i, s in enumerate(scales) if 0.95 <= s <= 1.05]
        swing = (max(band)-min(band))/abs(base) if base else float('nan')
        out[k] = dict(values=v, swing_pm5pct=swing)
    return dict(scales=list(scales), clues=out)

def run(path, roi, at=None, verbose=True):
    res = {'frame': path, 'runs': []}
    for md in ([None] + list(at or [])):
        rgb, lum, s = load(path, md)
        cx, cy, r = roi[0]*s, roi[1]*s, roi[2]*s
        gt = ground_truth(lum, cx, cy, r)
        snap = refine_to_limb(lum, cx, cy, r)
        entry = {'buffer': [lum.shape[1], lum.shape[0]],
                 'ground_truth': gt,
                 'refineToLimb': dict(cx=snap[0], cy=snap[1], r=snap[2],
                                      arc_hits=snap[3], rms_resid_over_r=snap[4])}
        if gt:
            entry['refineToLimb']['center_err_over_r'] = \
                math.hypot(snap[0]-gt['cx'], snap[1]-gt['cy'])/gt['r']
            entry['refineToLimb']['radius_err_pct'] = 100*(snap[2]/gt['r']-1)
            entry['ledger_at_ground_truth'] = ledger(rgb, lum, gt['cx'], gt['cy'], gt['r'])
            entry['conditioning'] = conditioning(rgb, lum, gt['cx'], gt['cy'], gt['r'])
        entry['ledger_at_refined'] = ledger(rgb, lum, *snap[:3])
        res['runs'].append(entry)
        if verbose: _print(entry, md)
    return res

def _print(e, md):
    b = e['buffer']; gt = e['ground_truth']; sn = e['refineToLimb']
    print(f"\n{'='*72}\nbuffer {b[0]}x{b[1]}" + (f"  (downscaled, maxDim={md})" if md else "  (native)"))
    if gt:
        print(f"  ground truth      c=({gt['cx']:.1f},{gt['cy']:.1f}) r={gt['r']:.1f}"
              f"   boundary RMS/r={gt['boundary_rms_over_r']:.4f}  circularity={gt['circularity']:.3f}")
    print(f"  refineToLimb      c=({sn['cx']:.1f},{sn['cy']:.1f}) r={sn['r']:.1f}"
          f"   arc {sn['arc_hits']}/{REFINE_RAYS}  RMSresid/r={sn['rms_resid_over_r']:.4f}")
    if 'center_err_over_r' in sn:
        print(f"                    vs GT: center err {sn['center_err_over_r']:.3f} r,"
              f" radius {sn['radius_err_pct']:+.1f}%")
    L = e.get('ledger_at_ground_truth') or e['ledger_at_refined']
    tag = 'at GROUND TRUTH' if 'ledger_at_ground_truth' in e else 'at refined ROI'
    print(f"\n  clue ledger ({tag})")
    print(f"    r/normW               {L['r_over_normW']:.4f}   [band {RADIUS_RATIO}, pf floor {PF_RADIUS_MIN}]")
    print(f"    interiorStd full r    {L['interiorStd_full_r']:.4f}   [pf ceiling {PF_STD_HARD_MAX}, floor {PF_STD_FLOOR}]")
    print(f"    interiorStd 0.85r     {L['interiorStd_085r']:.4f}   [gate {STDDEV_GATE}]")
    print(f"    chroma dist           {L['chroma_dist']:.4f}   [<= {CHROMA_MAX}]  R/G {L['rg']:.3f} B/G {L['bg']:.3f}")
    print(f"    lambertian viol       {L['lambertian_violations']}        rings "
          + " ".join(f"{x:.3f}" for x in L['rings'] if x is not None))
    print(f"    heroIRE               {L['heroIRE']:.2f}")
    print(f"    shadowRatio shipped   {L['shadowRatio_as_shipped']:.4f}  axis {L['shadow_axis_as_shipped_deg']:+.0f}deg"
          f"   [<= {SHADOW_MAX} pass, <= {SHADOW_MAX_PASS2} pass2]")
    print(f"    shadowRatio planefit  {L['shadowRatio_plane_fit']:.4f}  axis {L['shadow_axis_plane_fit_deg']:+.0f}deg")
    print(f"    ireSpread  +/-x       {L['ireSpread_hardcoded_x']:.3f} IRE   [>= {IRE_SPREAD_MIN}]")
    print(f"    ireSpread  on-axis    {L['ireSpread_on_axis']:.3f} IRE")
    c = e.get('conditioning')
    if c:
        print(f"\n  conditioning — value across radius scales {c['scales']}, swing over +/-5%")
        for k, v in c['clues'].items():
            print(f"    {k:<24} " + " ".join(f"{x:8.4f}" for x in v['values'])
                  + f"   | {100*v['swing_pm5pct']:5.1f}%")

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('frame')
    ap.add_argument('--roi', nargs=3, type=float, required=True, metavar=('CX','CY','R'))
    ap.add_argument('--at', nargs='*', type=int, default=[], help='extra maxDim buffers, e.g. --at 480')
    ap.add_argument('--json')
    a = ap.parse_args()
    out = run(a.frame, a.roi, a.at)
    if a.json:
        with open(a.json, 'w') as f: json.dump(out, f, indent=2, default=str)
        print(f"\nwrote {a.json}")
