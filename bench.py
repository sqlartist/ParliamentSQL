import time, numpy as np
from datasets import load_dataset

N = 2000
VEC_FMT = ",".join(["%.5f"] * 384)

vecs = np.load("hansard_emb.npy")
print("cache loaded")

t = time.time()
for i in range(N):
    s = "[" + (VEC_FMT % tuple(vecs[i].tolist())) + "]"
print(f"A  format only      : {N/(time.time()-t):10,.0f} rows/sec")

t = time.time()
with open("bench.tmp", "w", encoding="utf-8", newline="", buffering=1<<22) as f:
    for i in range(N):
        f.write("[" + (VEC_FMT % tuple(vecs[i].tolist())) + "]\x02")
print(f"B  format + write   : {N/(time.time()-t):10,.0f} rows/sec")

ds = load_dataset("biglam/hansard_speech", split="train")
ds = ds.filter(lambda r: r["speech"] and len(r["speech"].split()) >= 40
               and r["major_heading"], num_proc=8)
ds = ds.shuffle(seed=42)
print("dataset ready")

t = time.time()
col = ds["speech"]
print(f"C  materialise col  : {time.time()-t:10.1f} sec")

t = time.time()
n = 0
for b in ds.iter(batch_size=5000):
    n += len(b["speech"])
    if n >= N: break
print(f"D  stream batches   : {n/(time.time()-t):10,.0f} rows/sec")