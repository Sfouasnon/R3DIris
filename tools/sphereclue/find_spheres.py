import glob,math,os,json
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
exec(open('find_spheres.py').read().split('def find_sphere')[0])

def find(rgb,lum):
    h,w=lum.shape; normW=min(w,h*16/9); rmin,rmax=0.012*normW,0.32*normW
    best=None
    for t in np.arange(0.18,0.72,0.02):
        m=ndimage.binary_opening(lum>t,np.ones((7,7)))
        lab,n=ndimage.label(m)
        if n==0 or n>500: continue
        for k,sl in enumerate(ndimage.find_objects(lab),start=1):
            blob=(lab[sl]==k); area=blob.sum()
            if area<400: continue
            if not(rmin<=math.sqrt(area/math.pi)<=rmax): continue
            ys0,xs0=sl[0].start,sl[1].start
            if ys0==0 or xs0==0 or sl[0].stop>=h or sl[1].stop>=w: continue
            fill=area/(blob.shape[0]*blob.shape[1]); asp=blob.shape[0]/blob.shape[1]
            if not(0.62<=fill<=0.90) or not(0.82<=asp<=1.22): continue
            edge=blob&~ndimage.binary_erosion(blob)
            by,bx=np.nonzero(edge); bx=(bx+xs0).astype(float); by=(by+ys0).astype(float)
            if len(bx)<30: continue
            f=kasa(bx,by)
            if f is None: continue
            fcx,fcy,fr=f
            if not(rmin<=fr<=rmax): continue
            res=np.abs(np.hypot(bx-fcx,by-fcy)-fr)
            # robust: trim worst 25% (limb merged with an adjacent card breaks a quarter of the boundary)
            keep=res<=np.sort(res)[int(len(res)*0.75)]
            f2=kasa(bx[keep],by[keep])
            if f2 is None: continue
            fcx,fcy,fr=f2
            rms=float(np.abs(np.hypot(bx[keep]-fcx,by[keep]-fcy)-fr).mean()/fr)
            if rms>0.05: continue
            ys,xs=np.nonzero(blob); ys=ys+ys0; xs=xs+xs0
            sr,sg,sb=rgb[ys,xs,0].sum(),rgb[ys,xs,1].sum(),rgb[ys,xs,2].sum(); tot=sr+sg+sb
            ch=math.hypot(sr/tot-1/3,sg/tot-1/3)
            if ch>0.045: continue
            score=fr*(1-4*rms)
            if best is None or score>best['score']:
                best=dict(cx=fcx,cy=fcy,r=fr,rms=rms,fill=float(fill),chroma=ch,
                          thresh=float(t),score=score,mean_lum=float(lum[ys,xs].mean()))
    return best

rows=[]
for p in sorted(glob.glob('/root/.claude/uploads/*/*.png')):
    im=Image.open(p); rgb,lum=luma_of(im)
    nm=os.path.basename(p).split('-')[-1].replace('Screenshot_20260811_at_','').replace('.png','')
    s=find(rgb,lum)
    if s is None: print(f"{nm:<12} MISS"); continue
    rows.append(dict(path=p,name=nm,**s,w=im.width,h=im.height))
    print(f"{nm:<12} c=({s['cx']:7.1f},{s['cy']:6.1f}) r={s['r']:6.1f} rms/r={s['rms']:.4f} "
          f"fill={s['fill']:.2f} chroma={s['chroma']:.4f} meanLum={s['mean_lum']:.3f}")
    d=ImageDraw.Draw(im)
    d.ellipse([s['cx']-s['r'],s['cy']-s['r'],s['cx']+s['r'],s['cy']+s['r']],outline=(255,0,255),width=5)
    b=(max(0,int(s['cx']-2.3*s['r'])),max(0,int(s['cy']-2.3*s['r'])),
       min(im.width,int(s['cx']+2.3*s['r'])),min(im.height,int(s['cy']+2.3*s['r'])))
    im.crop(b).resize((320,320)).save(f'corpus/v2_{nm}.png')
json.dump(rows,open('corpus/spheres.json','w'),indent=1)
print(f"\n{len(rows)}/15 located")
