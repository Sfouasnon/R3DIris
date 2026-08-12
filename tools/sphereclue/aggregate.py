import json,math,sys,numpy as np
sys.argv=['x']
exec(open('clue_ledger.py').read().split("if __name__")[0])
rows=json.load(open('corpus/spheres.json'))
R=[]
for s in rows:
    rgb,lum,_=load(s['path'],None)
    L=ledger(rgb,lum,s['cx'],s['cy'],s['r'])
    sn=refine_to_limb(lum,s['cx'],s['cy'],s['r'])
    C=conditioning(rgb,lum,s['cx'],s['cy'],s['r'])
    R.append(dict(name=s['name'],r=s['r'],gt_rms=s['rms'],mean_lum=s['mean_lum'],L=L,
        snap_cerr=math.hypot(sn[0]-s['cx'],sn[1]-s['cy'])/s['r'], snap_rerr=100*(sn[2]/s['r']-1),
        snap_arc=sn[3], snap_rms=sn[4],
        cond={k:v['swing_pm5pct'] for k,v in C['clues'].items()}))

print(f"{'frame':<12}{'r':>6}{'r/nW':>7}{'heroIRE':>8}{'std.85':>8}{'stdFull':>8}{'chroma':>8}"
      f"{'shadSHIP':>9}{'shadFIT':>8}{'axisΔ':>7}{'ireSpr':>7}{'lam':>4}")
for x in R:
    L=x['L']; ad=abs(((L['shadow_axis_as_shipped_deg']-L['shadow_axis_plane_fit_deg'])+180)%360-180)
    print(f"{x['name']:<12}{x['r']:6.0f}{L['r_over_normW']:7.4f}{L['heroIRE']:8.1f}"
          f"{L['interiorStd_085r']:8.4f}{L['interiorStd_full_r']:8.4f}{L['chroma_dist']:8.4f}"
          f"{L['shadowRatio_as_shipped']:9.4f}{L['shadowRatio_plane_fit']:8.4f}{ad:7.0f}"
          f"{L['ireSpread_hardcoded_x']:7.2f}{L['lambertian_violations']:4d}")

def col(k): return np.array([x['L'][k] for x in R],float)
n=len(R)
print(f"\n--- GATE OUTCOMES on {n} real spheres (as coded, at TRUE geometry) ---")
sh_s,sh_f=col('shadowRatio_as_shipped'),col('shadowRatio_plane_fit')
print(f"  shadow_specular <=0.960 (primary): as-shipped {int((sh_s<=0.96).sum())}/{n} pass   "
      f"plane-fit {int((sh_f<=0.96).sum())}/{n} pass")
print(f"  shadow pass2    <=0.985          : as-shipped {int((sh_s<=0.985).sum())}/{n}          "
      f"plane-fit {int((sh_f<=0.985).sum())}/{n}")
print(f"     -> as-shipped forces {int(((sh_s>0.96)&(sh_s<=0.985)).sum())} frames into the pass2 escape hatch;"
      f" plane-fit forces {int(((sh_f>0.96)&(sh_f<=0.985)).sum())}")
sf=col('interiorStd_full_r')
print(f"  prefilter G2 std(full r) <=0.130 : {int((sf<=0.130).sum())}/{n} pass  "
      f"(fails: {[x['name'] for x in R if x['L']['interiorStd_full_r']>0.130]})")
print(f"  gate interiorStd(0.85r) 0.003-0.170: {int(((col('interiorStd_085r')>=0.003)&(col('interiorStd_085r')<=0.170)).sum())}/{n}")
print(f"  gray_material chroma <=0.045     : {int((col('chroma_dist')<=0.045).sum())}/{n}   "
      f"[range {col('chroma_dist').min():.4f}-{col('chroma_dist').max():.4f}]")
print(f"  ire_spread >=0.8 (hardcoded x)   : {int((col('ireSpread_hardcoded_x')>=0.8).sum())}/{n}   "
      f"[range {col('ireSpread_hardcoded_x').min():.2f}-{col('ireSpread_hardcoded_x').max():.2f}]")
print(f"  lambertian 0 violations          : {int((np.array([x['L']['lambertian_violations'] for x in R])==0).sum())}/{n}")
print(f"  geometry r/normW in 0.02-0.32    : {int(((col('r_over_normW')>=0.02)&(col('r_over_normW')<=0.32)).sum())}/{n}"
      f"   [range {col('r_over_normW').min():.4f}-{col('r_over_normW').max():.4f}]")

ad=np.array([abs(((x['L']['shadow_axis_as_shipped_deg']-x['L']['shadow_axis_plane_fit_deg'])+180)%360-180) for x in R])
print(f"\n  shading-axis disagreement (shipped vs plane-fit): median {np.median(ad):.0f}deg, max {ad.max():.0f}deg")
print(f"  heroIRE across corpus: {col('heroIRE').min():.1f}-{col('heroIRE').max():.1f} (spread {col('heroIRE').max()-col('heroIRE').min():.1f} IRE)")

print(f"\n--- refineToLimb vs true geometry ({n} frames) ---")
ce=np.array([x['snap_cerr'] for x in R]); re_=np.array([x['snap_rerr'] for x in R])
print(f"  center error / r : median {np.median(ce):.3f}  max {ce.max():.3f}   ({int((ce>0.10).sum())}/{n} worse than 0.10r)")
print(f"  radius error %   : median {np.median(re_):+.1f}  max {re_.max():+.1f}  ({int((re_>5).sum())}/{n} oversized by >5%)")
print(f"  its own RMSresid/r: median {np.median([x['snap_rms'] for x in R]):.4f}"
      f"   vs true boundary RMS/r median {np.median([x['gt_rms'] for x in R]):.4f}")

print(f"\n--- CONDITIONING: median swing under +/-5% radius error ({n} frames) ---")
for k in R[0]['cond']:
    v=np.array([x['cond'][k] for x in R],float)*100
    print(f"  {k:<26} median {np.median(v):6.1f}%   max {v.max():6.1f}%")
json.dump(R,open('corpus/ledger_all.json','w'),indent=1,default=str)
