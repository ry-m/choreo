#!/usr/bin/env python3
"""Write a test vector (features + PyTorch outputs) so the C++ BeatNet can be checked for an
exact match. Usage: export_testvec.py MODEL.bin.pt OUT.bin [CHANNELS]"""
import json, os, sys
import numpy as np
import torch
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train_beats import BeatNet, ML

pt, out = sys.argv[1], sys.argv[2]
ch = int(sys.argv[3]) if len(sys.argv) > 3 else 48
model = BeatNet(c=ch)
model.load_state_dict(torch.load(pt, map_location="cpu"))
model.eval()
e = next(e for e in json.load(open(f"{ML}/features/index.json")) if e["test"])
T, D = np.fromfile(e["file"], dtype=np.int32, count=2)
x = np.fromfile(e["file"], dtype=np.float32, offset=12).reshape(T, D)[:600].copy()
with torch.no_grad():
    y = torch.sigmoid(model(torch.from_numpy(x).unsqueeze(0)))[0].numpy()
with open(out, "wb") as f:
    np.array([x.shape[0], x.shape[1]], np.int32).tofile(f)
    x.astype(np.float32).tofile(f)
    y.astype(np.float32).tofile(f)
print(f"wrote {out}: {x.shape[0]} frames from {e['name']}")
