#!/usr/bin/env python3
"""Train Choreo's learned beat/downbeat detector: a causal temporal convolutional network.

Input: 128-dim features at 100 fps from build/choreo-features (see build_dataset.py).
Output: per-frame beat and downbeat activations (0..1), delayed by LOOKAHEAD frames so the
network may look that far into the "future" while staying usable live (Choreo predicts the
beat forward anyway). The model is causal, so the C++ runtime can run it frame by frame.

Usage: train_beats.py [--epochs N] [--channels C] [--out models/beatnet.bin]
"""
import argparse, json, math, os, random, time
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

ML = os.environ.get("CHOREO_ML", os.path.expanduser("~/.cache/choreo/ml"))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FPS = 100
LOOKAHEAD = 2           # frames (20 ms)
DILATIONS = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024]
KERNEL = 3


# --------------------------------------------------------------------------- model
class CausalConv(nn.Conv1d):
    def __init__(self, cin, cout, k, d=1):
        super().__init__(cin, cout, k, dilation=d)
        self.left = (k - 1) * d

    def forward(self, x):
        return super().forward(F.pad(x, (self.left, 0)))


class Block(nn.Module):
    def __init__(self, c, d, drop):
        super().__init__()
        self.conv = CausalConv(c, c, KERNEL, d)
        self.mix = nn.Conv1d(c, c, 1)
        self.drop = nn.Dropout(drop)

    def forward(self, x):
        return x + self.mix(self.drop(F.elu(self.conv(x))))


class BeatNet(nn.Module):
    def __init__(self, dim=128, c=48, drop=0.15):
        super().__init__()
        self.inp = CausalConv(dim, c, KERNEL, 1)
        self.blocks = nn.ModuleList([Block(c, d, drop) for d in DILATIONS])
        self.out = nn.Conv1d(c, 2, 1)

    def forward(self, x):            # x: [B, T, dim] -> logits [B, T, 2]
        h = F.elu(self.inp(x.transpose(1, 2)))
        for b in self.blocks:
            h = b(h)
        return self.out(h).transpose(1, 2)


# --------------------------------------------------------------------------- data
class Clip:
    def __init__(self, e):
        self.file, self.name, self.test = e["file"], e["name"], e["test"]
        hdr = np.fromfile(self.file, dtype=np.int32, count=2)
        self.T, self.D = int(hdr[0]), int(hdr[1])
        self.off = float(np.fromfile(self.file, dtype=np.float32, count=1, offset=8)[0])
        self.x = np.memmap(self.file, dtype=np.float32, mode="r", offset=12, shape=(self.T, self.D))
        self.beats, self.downs = e["beats"], e["downbeats"]
        self.yb = self.target(self.beats)
        self.yd = self.target(self.downs)

    def target(self, times):
        y = np.zeros(self.T, np.float32)
        for t in times:
            k = int(round((t - self.off) * FPS))
            for dk, v in ((0, 1.0), (-1, 0.5), (1, 0.5)):   # widened target (+-10 ms)
                if 0 <= k + dk < self.T:
                    y[k + dk] = max(y[k + dk], v)
        return y

    def crop(self, n):
        s = random.randint(0, max(0, self.T - n))
        x = np.asarray(self.x[s:s + n])
        yb, yd = self.yb[s:s + n], self.yd[s:s + n]
        return x, yb, yd


def shift(y, d):
    """Output frame t predicts the label at t-d."""
    out = torch.zeros_like(y)
    out[:, d:] = y[:, :-d] if d else y
    return out


# --------------------------------------------------------------------------- eval
def peaks(act, thr=0.4, w=7):
    out = []
    for t in range(len(act)):
        if act[t] >= thr and act[t] == act[max(0, t - w):t + w + 1].max():
            out.append(t)
    return out


def fmeasure(est, ref, win=0.07):
    if not est or not ref:
        return 0.0
    ref = list(ref); used = [False] * len(ref); hits = 0
    for e in est:
        for i, r in enumerate(ref):
            if not used[i] and abs(e - r) <= win:
                used[i] = True; hits += 1; break
    p, r = hits / len(est), hits / len(ref)
    return 2 * p * r / (p + r) if p + r else 0.0


@torch.no_grad()
def evaluate(model, clips, dev):
    model.eval()
    fb, fd = [], []
    for c in clips:
        x = torch.from_numpy(np.asarray(c.x)).unsqueeze(0).to(dev)
        a = torch.sigmoid(model(x))[0].cpu().numpy()
        for j, (lst, ref) in enumerate(((fb, c.beats), (fd, c.downs))):
            # undo the lookahead delay: output frame t refers to frame t - LOOKAHEAD
            est = [(t - LOOKAHEAD) / FPS + c.off for t in peaks(a[:, j])]
            r = [t for t in ref if t >= 5]; e = [t for t in est if t >= 5]
            if r:
                lst.append(fmeasure(e, r))
    model.train()
    return float(np.mean(fb)), float(np.mean(fd)) if fd else 0.0


# --------------------------------------------------------------------------- export
def export(model, path, c):
    """Raw little-endian float32 weights in a fixed order (read by src/analysis/BeatNet.cpp)."""
    sd = {k: v.detach().cpu().float().numpy() for k, v in model.state_dict().items()}
    with open(path, "wb") as f:
        hdr = np.array([0x42454154, 1, 128, c, KERNEL, len(DILATIONS), LOOKAHEAD], np.int32)  # 'BEAT'
        hdr.tofile(f)
        np.array(DILATIONS, np.int32).tofile(f)
        def put(k):
            sd[k].astype(np.float32).tofile(f)
        put("inp.weight"); put("inp.bias")
        for i in range(len(DILATIONS)):
            for k in ("conv.weight", "conv.bias", "mix.weight", "mix.bias"):
                put(f"blocks.{i}.{k}")
        put("out.weight"); put("out.bias")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--steps", type=int, default=400)
    ap.add_argument("--batch", type=int, default=24)
    ap.add_argument("--crop", type=int, default=1200)
    ap.add_argument("--channels", type=int, default=48)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--out", default=os.path.join(ROOT, "models", "beatnet.bin"))
    args = ap.parse_args()

    random.seed(0); torch.manual_seed(0)
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    index = json.load(open(f"{ML}/features/index.json"))
    clips = [Clip(e) for e in index if os.path.exists(e["file"])]
    train = [c for c in clips if not c.test]
    test = [c for c in clips if c.test]
    print(f"device {dev}; {len(train)} train files, {len(test)} test clips", flush=True)

    model = BeatNet(c=args.channels).to(dev)
    print(f"parameters: {sum(p.numel() for p in model.parameters())}", flush=True)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    total = args.epochs * args.steps
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=total, pct_start=0.1)
    pos_w = torch.tensor([4.0, 12.0], device=dev)   # beats ~2% of frames, downbeats ~0.5%

    best = -1
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    for ep in range(args.epochs):
        t0, losses = time.time(), []
        for _ in range(args.steps):
            xs, yb, yd = zip(*(random.choice(train).crop(args.crop) for _ in range(args.batch)))
            n = min(len(a) for a in xs)
            x = torch.from_numpy(np.stack([a[:n] for a in xs])).to(dev)
            y = torch.stack([torch.from_numpy(np.stack([a[:n] for a in yb])),
                             torch.from_numpy(np.stack([a[:n] for a in yd]))], -1).to(dev)
            y = shift(y, LOOKAHEAD)
            logits = model(x)
            w = 1 + (pos_w - 1) * (y > 0)
            loss = F.binary_cross_entropy_with_logits(logits, y, weight=w)
            opt.zero_grad(); loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step(); sched.step()
            losses.append(loss.item())
        fb, fd = evaluate(model, test, dev)
        msg = f"epoch {ep + 1:3d}/{args.epochs}  loss {np.mean(losses):.4f}  test beat F {fb:.3f}  downbeat F {fd:.3f}  ({time.time() - t0:.0f}s)"
        if fb > best:
            best = fb
            export(model, args.out, args.channels)
            torch.save(model.state_dict(), args.out + ".pt")
            msg += "  * saved"
        print(msg, flush=True)


if __name__ == "__main__":
    main()
