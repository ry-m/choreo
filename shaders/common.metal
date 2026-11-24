// Shared by every scene and post pass (prepended at load time).
#include <metal_stdlib>
using namespace metal;

// Must match SceneUniforms in src/render/Director.h.
struct Frame {
    float4 res;    // w, h, time, sceneTime
    float4 rhythm; // beatPhase, barPhase, beatPulse, barPulse
    float4 hits;   // kick, snare, hat, onset
    float4 spec;   // bass, mid, treble, loudness
    float4 dyn;    // energy, intensity, build, brightness
    float4 motion; // travel, spin, orbit, camKick
    float4 cam;    // preset (eased), shake, roll, fovPunch
    float4 fx;     // flash, burstAge, shatter, strobe
    float4 look;   // variant (eased), seed, hue drift, beatPresent
    float4 palA, palB, palC, palD;
    float4 hist;   // newest history row (0..255), rows per second, bar move (+1 per bar, eased: lurches into each bar)
    float4 accA, accB, accC, accD;  // accent palette (a second anchor in a harmony hue)
    float4 hr0, hr1, hr2;           // primary palette hue rotation (rows)
    float4 ar0, ar1, ar2;           // accent palette hue rotation (rows)
    float4 gene0, gene1;            // 8 random genes (0..1), re-rolled per cut, partly per section
    float4 bands;  // sub, body, voice (sustained mids: vocals/pads/leads), air (hi shimmer: hats/claps)
};

// Noise volume (bound to every scene as texture 1 / sampler 1, repeat): 64^3 RGBA8, tileable,
// 8 noise cells per tile. R, G: independent gradient noise (0..1, mean 0.5); B: Worley F1 (distance
// to the nearest feature point, ~0..1); A: Worley F2 - F1 (0 on cell borders: cracks, veins, facets).
#define NOISE_ARGS texture3d<float> nzt [[texture(1)]], sampler nzs [[sampler(1)]]
#define NZ nzt, nzs
#define NZP texture3d<float> nzt, sampler nzs
// All four channels at p, in noise-cell units (period 8).
static float4 nz4(NZP, float3 p) { return nzt.sample(nzs, p * 0.125); }
// Gradient-noise fbm from the volume (R channel), 0..1, mean 0.5, contrast-normalised so it spans
// about the same range as one octave of value noise (std ~0.17). Octaves are rotated to hide the lattice.
static float nfbm(NZP, float3 p, int oct) {
    const float3x3 m = float3x3(float3(0.00, 0.80, 0.60), float3(-0.80, 0.36, -0.48), float3(-0.60, -0.48, 0.64)) * 2.02;
    float a = 0.5, s = 0.0;
    for (int i = 0; i < oct; ++i) { s += a * (nzt.sample(nzs, p * 0.125).r - 0.5); p = m * p + 0.37; a *= 0.5; }
    return clamp(0.5 + 1.95 * s, 0.0, 1.0);
}
// Ridged multifractal (sharp crests: lightning, veins, marble), 0..1.
static float nridge(NZP, float3 p, int oct) {
    const float3x3 m = float3x3(float3(0.00, 0.80, 0.60), float3(-0.80, 0.36, -0.48), float3(-0.60, -0.48, 0.64)) * 2.02;
    float a = 0.5, s = 0.0, w = 0.0, prev = 1.0;
    for (int i = 0; i < oct; ++i) {
        float n = 1.0 - abs(nzt.sample(nzs, p * 0.125).g * 2.0 - 1.0);
        n *= n;
        s += a * n * prev; w += a; prev = n;
        p = m * p + 0.71; a *= 0.5;
    }
    return s / w;
}
// Domain-warped fbm (marbled, flowing): q warps p by two noise channels first.
static float nwarp(NZP, float3 p, float amt, int oct) {
    float4 q = nzt.sample(nzs, p * 0.125 * 0.5);
    return nfbm(NZ, p + (q.rgr - 0.5) * amt * 2.0, oct);
}

// Music history (bound to every scene as texture 0 / sampler 0; see HistoryRow in Director.h).
#define HIST_ARGS texture2d<float> hist [[texture(0)]], sampler hs [[sampler(0)]]
constant float HIST_ROWS = 256.0;
constant float HIST_COLS = 32.0;
// Row v coordinate for an age in seconds (0 = now); the sampler repeats in v (ring buffer).
static float histV(constant Frame& u, float ageSec) {
    float row = u.hist.x - clamp(ageSec * u.hist.y, 0.0, HIST_ROWS - 2.0);
    return (row + 0.5) / HIST_ROWS;
}
// Spectrum (x = 0..1 low to high, linearly interpolated between bands) at an age in seconds.
static float4 histSpec(texture2d<float> hist, sampler hs, constant Frame& u, float x, float ageSec) {
    float c = clamp(x, 0.0, 1.0) * (HIST_COLS - 1.0) + 0.5;
    return hist.sample(hs, float2(c / HIST_COLS, histV(u, ageSec)));
}
// Scalar column k (0 kick, 1 snare, 2 hat, 3 bass, 4 loudness, 5 beat pulse, 6 onset, 7 energy).
static float histScalar(texture2d<float> hist, sampler hs, constant Frame& u, int k, float ageSec) {
    return hist.sample(hs, float2((float(k) + 0.5) / HIST_COLS, histV(u, ageSec))).b;
}

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

constant float TAU = 6.2831853;

static float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(c, -s, s, c); }
static float modf1(float x, float y) { return x - y * floor(x / y); }
static float sat(float x) { return clamp(x, 0.0, 1.0); }

// Primary and accent palettes (cosine palettes, hue-rotated by the director's remix).
static float3 pal(constant Frame& u, float t) {
    float3 c = u.palA.xyz + u.palB.xyz * cos(TAU * (u.palC.xyz * t + u.palD.xyz));
    return max(float3(dot(u.hr0.xyz, c), dot(u.hr1.xyz, c), dot(u.hr2.xyz, c)), 0.0);
}
static float3 acc(constant Frame& u, float t) {
    float3 c = u.accA.xyz + u.accB.xyz * cos(TAU * (u.accC.xyz * t + u.accD.xyz));
    return max(float3(dot(u.ar0.xyz, c), dot(u.ar1.xyz, c), dot(u.ar2.xyz, c)), 0.0);
}
// Gene k (0..7).
static float gene(constant Frame& u, int k) { return k < 4 ? u.gene0[k] : u.gene1[k - 4]; }
// Discrete choice from a gene: 0..n-1.
static int geneI(constant Frame& u, int k, int n) { return min(int(gene(u, k) * float(n)), n - 1); }

static float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
static float hash21(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
static float hash31(float3 p3) { p3 = fract(p3 * 0.1031); p3 += dot(p3, p3.zyx + 31.32); return fract((p3.x + p3.y) * p3.z); }
static float3 hash33(float3 p3) {
    p3 = fract(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// Smooth 3D value noise in [0,1].
static float noise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i), n100 = hash31(i + float3(1, 0, 0)), n010 = hash31(i + float3(0, 1, 0)), n110 = hash31(i + float3(1, 1, 0));
    float n001 = hash31(i + float3(0, 0, 1)), n101 = hash31(i + float3(1, 0, 1)), n011 = hash31(i + float3(0, 1, 1)), n111 = hash31(i + float3(1, 1, 1));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y), mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}
static float fbm3(float3 p, int oct) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < oct; ++i) { s += a * noise3(p); p = p * 2.03 + float3(1.7, 9.2, 3.1); a *= 0.5; }
    return s;
}

// Camera basis looking from ro at ta, with roll.
static float3x3 lookAt(float3 ro, float3 ta, float roll) {
    float3 w = normalize(ta - ro);
    float3 up = float3(sin(roll), cos(roll), 0.0);
    float3 uu = normalize(cross(up, w));
    float3 vv = cross(w, uu);
    return float3x3(uu, vv, w);
}

// Screen position, aspect-correct, y up, centred.
static float2 screenUV(VOut in, constant Frame& u) {
    float2 p = (in.uv * u.res.xy - 0.5 * u.res.xy) / u.res.y;
    return float2(p.x, -p.y);
}

// Per-pixel dither in [0,1) that changes every frame (feedback averages it into smooth volumes).
static float frameDither(VOut in, constant Frame& u) {
    return fract(hash21(in.uv * u.res.xy) + u.res.z * 7.13);
}

// Glow from a horizontal light ring (centre c, radius R) seen along a ray: distance from the
// ray's crossing of the ring's plane to the circle.
static float ringGlow(float3 ro, float3 rd, float3 c, float R, float width, float tMax) {
    if (abs(rd.y) < 1e-4) return 0.0;
    float t = (c.y - ro.y) / rd.y;
    if (t <= 0.0 || t > tMax) return 0.0;
    float3 p = ro + rd * t;
    float d = abs(length(p.xz - c.xz) - R);
    return width / (width + d * d * 40.0) * exp(-t * 0.04);
}

static float sdBox(float3 p, float3 b) { float3 q = abs(p) - b; return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0); }
static float smin(float a, float b, float k) { float h = sat(0.5 + 0.5 * (b - a) / k); return mix(b, a, h) - k * h * (1.0 - h); }
