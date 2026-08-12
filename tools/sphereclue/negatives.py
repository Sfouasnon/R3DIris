import glob,math,os,json,sys,numpy as np
from PIL import Image
from scipy import ndimage
sys.argv=['x']
exec(open('clue_ledger.py').read().split("if __name__")[0])

def blobs(rgb,lum,want_card):
    """want_card=True -> high-fill achromatic rectangles (gray/white cards, monitors)."""
    h,w=lum.shape; normW=min(w,h*16/9); rmin,rmax=0.015*normW,0.32*normW
    out=[]
    for t in np.arange(0.20,0.70,0.04):
        m=ndimage.binary_opening(lum>t,np.ones((7,7)))
        lab,n=ndimage.label(m)
        if n==0 or n>500: continue
        for k,sl in enumerate(ndimage.find_objects(lab),start=1):
            blob=(lab[sl]==k); area=blob.sum()
            if area<800: continue
            r_area=math.sqrt(area/math.pi)
            if not(rmin<=r_area<=rmax): continue
            ys0,xs0=sl[0].start,sl[1].start
            if ys0==0 or xs0==0 or sl[0].stop>=h or sl[1].stop>=w: continue
            fill=area/(blob.shape[0]*blob.shape[1]); asp=blob.shape[0]/blob.shape[1]
            if want_card and not (fill>=0.93 and 0.5<=asp<=2.2): continue
            ys,xs=np.nonzero(blob); ys+=ys0; xs+=xs0
            sr,sg,sb=rgb[ys,xs,0].sum(),rgb[ys,xs,1].sum(),rgb[ys,xs,2].sum(); tot=sr+sg+sb
            ch=math.hypot(sr/tot-1/3,sg/tot-1/3)
            if ch>0.045: continue
            cx,cy=xs.mean(),ys.mean()
            out.append(dict(cx=float(cx),cy=float(cy),r=float(r_area),fill=float(fill),
                            asp=float(asp),chroma=ch,area=int(area),
                            mean_lum=float(lum[ys,xs].mean())))
    # dedupe by position
    keep=[]
    for c in sorted(out,key=lambda c:-c['area']):
        if all(math.hypot(c['cx']-k['cx'],c['cy']-k['cy'])>0.7*max(c['r'],k['r']) for k in keep):
            keep.append(c)
    return keep

def circ_convex(lum,cx,cy,r):
    """The two clues Stephen ranks load-bearing: circularity (arc+fit) and convexity."""
    scx,scy,sr,arc,rms = refine_to_limb(lum,cx,cy,r)
    ax,grad = axis_plane_fit(lum,scx,scy,sr)
    return dict(arc=arc/REFINE_RAYS, fit_rms=rms, shadow=shadow_ratio(lum,scx,scy,sr,ax),
                grad=grad, r=sr)

sph=json.load(open('corpus/spheres.json'))
POS,NEG=[],[]
for s in sph:
    rgb,lum,_=load(s['path'],None)
    m=circ_convex(lum,s['cx'],s['cy'],s['r']); m['name']=s['name']; m['kind']='sphere'
    m['mean_lum']=s['mean_lum']; POS.append(m)
    for c in blobs(rgb,lum,want_card=True)[:3]:
        q=circ_convex(lum,c['cx'],c['cy'],c['r'])
        q.update(name=s['name'],kind='card',fill=c['fill'],mean_lum=c['mean_lum'])
        NEG.append(q)

def stat(A,k):
    v=np.array([a[k] for a in A],float); v=v[np.isfinite(v)]
    return v
print(f"POSITIVES: {len(POS)} real spheres     NEGATIVES: {len(NEG)} flat achromatic cards/panels\n")
print(f"{'clue':<26}{'spheres  med [min-max]':<30}{'cards  med [min-max]':<30}{'separates?'}")
for k,lbl in [('arc','arc coverage (hits/48)'),('fit_rms','Kasa fit RMS resid / r'),
              ('shadow','shadowRatio (plane-fit)'),('grad','shading |grad| per px'),
              ('mean_lum','mean luma')]:
    p,q=stat(POS,k),stat(NEG,k)
    ov = not (p.max()<q.min() or q.max()<p.min())
    print(f"{lbl:<26}{np.median(p):7.4f} [{p.min():.4f}-{p.max():.4f}]  "
          f"{np.median(q):9.4f} [{q.min():.4f}-{q.max():.4f}]   {'OVERLAP' if ov else 'CLEAN SPLIT'}")

# combined 2-clue decision: circular AND convex
def rule(a): return (a['fit_rms']<0.10) and (a['shadow']<=0.95)
tp=sum(rule(a) for a in POS); fp=sum(rule(a) for a in NEG)
print(f"\n  2-clue rule [fit_rms < 0.10 AND shadowRatio <= 0.95]:")
print(f"     spheres accepted {tp}/{len(POS)}      cards accepted {fp}/{len(NEG)}")
for a in NEG:
    if rule(a): print(f"       card FP @ {a['name']}: fit_rms={a['fit_rms']:.4f} shadow={a['shadow']:.4f} r={a['r']:.0f}")
json.dump(dict(pos=POS,neg=NEG),open('corpus/pos_neg.json','w'),indent=1,default=str)
