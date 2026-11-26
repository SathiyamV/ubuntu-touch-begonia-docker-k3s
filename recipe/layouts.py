import re, shlex, subprocess, os, sys, collections
H=os.path.expanduser("~/kernel-build"); P=H+"/probe"
def cmdline(outdir):
    t=open(f"{outdir}/kernel/.fork.o.cmd").read()
    c=re.search(r"^cmd_kernel/fork.o := (.*)$",t,re.M).group(1)
    a=shlex.split(c); out=[]; i=0
    while i<len(a):
        x=a[i]
        if x.startswith("-Wp,") or x in("-c","-g"): i+=1; continue
        if x=="-o": i+=2; continue
        if x.endswith("kernel/fork.c") or x=="kernel/fork.c": i+=1; continue
        out.append(x); i+=1
    return out
def run(outdir, src, extra):
    return subprocess.run(cmdline(outdir)+["-I"+P]+extra+[src], cwd=outdir, capture_output=True, text=True)
names=None
for tag,out in (("stock",H+"/out-stock"),("min",H+"/out-min")):
    r=run(out, P+"/probe.c", ["-E","-w"]); assert r.returncode==0, r.stderr[:500]
    open(f"{P}/{tag}.i","w").write(r.stdout)
    got=set(re.findall(r"^\s*struct\s+(\w+)\s*\{",r.stdout,re.M)); names=got if names is None else names&got
names=sorted(n for n in names if not n.startswith("__")); print("structs defined in both:",len(names))
for tag,out in (("stock",H+"/out-stock"),("min",H+"/out-min")):
    src=P+"/probe2.c"
    open(src,"w").write('#include "headers.h"\n'+"".join(f"unsigned long __sz_{n} = sizeof(struct {n});\n" for n in names))
    r=run(out, src, ["-fsyntax-only","-w","-Xclang","-fdump-record-layouts"])
    open(f"{P}/layout-{tag}.txt","w").write(r.stdout); print(tag,"rc",r.returncode,"bytes",len(r.stdout), r.stderr[:300].replace("\n"," "))
def parse(p):
    d={}; cur=None; buf=[]
    for l in open(p):
        if l.startswith("*** Dumping AST Record Layout"):
            if cur: d[cur]="".join(buf)
            cur=None; buf=[]; continue
        m=re.match(r"^\s*0 \| struct (\w+)\s*$",l)
        if m and cur is None: cur=m.group(1)
        buf.append(re.sub(r"^\s*\d+(:\d+-\d+)?\s*\|","",l) if False else l)
    if cur: d[cur]="".join(buf)
    return d
a=parse(P+"/layout-stock.txt"); b=parse(P+"/layout-min.txt")
common=sorted(set(a)&set(b)); diff=[n for n in common if a[n]!=b[n]]
print("layouts compared:",len(common),"| DIFFERENT:",len(diff)); print(diff)
open(P+"/diff-names.txt","w").write("\n".join(diff))
