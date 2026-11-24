// Post passes (after common.metal): feedback trails, bloom chain, final composite, calibration.

struct PostU {
    float4 src0;  // uv scale of input 0 (active region / texture), texel size
    float4 src1;
    float4 p0, p1, p2;
};

// Map a 0..1 uv over the active region to texture uv, clamped half a texel inside it.
static float2 suv(float2 uv, float4 s) { return clamp(uv, 0.0, 1.0) * s.xy; }
static float3 tap(texture2d<float> t, sampler sm, float2 uv, float4 s) {
    float2 q = min(uv * s.xy, s.xy - 0.5 * s.zw);
    return t.sample(sm, max(q, 0.5 * s.zw)).rgb;
}

// FXAA-style edge smoothing of the raymarched scene (run inside the feedback pass, so it costs a few
// taps instead of a pass): find the local edge direction from the four diagonal neighbours and blend
// along it. Only where the contrast says there is an edge; flat areas keep their detail.
static float fxLuma(float3 c) { c = c / (1.0 + c); return dot(c, float3(0.299, 0.587, 0.114)); }
static float3 fxaa(texture2d<float> t, sampler sm, float2 uv, float4 s) {
    float2 px = s.zw / s.xy;   // one texel in active-region uv
    float3 cM = tap(t, sm, uv, s);
    float lM = fxLuma(cM);
    float lNW = fxLuma(tap(t, sm, uv + px * float2(-1, -1), s)), lNE = fxLuma(tap(t, sm, uv + px * float2(1, -1), s));
    float lSW = fxLuma(tap(t, sm, uv + px * float2(-1, 1), s)), lSE = fxLuma(tap(t, sm, uv + px * float2(1, 1), s));
    float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE))), lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
    if (lMax - lMin < max(0.04, lMax * 0.15)) return cM;
    float2 dir = float2(-((lNW + lNE) - (lSW + lSE)), (lNW + lSW) - (lNE + lSE));
    float reduce = max((lNW + lNE + lSW + lSE) * 0.03125, 1.0 / 128.0);
    dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), -6.0, 6.0) * px;
    float3 a = 0.5 * (tap(t, sm, uv - dir / 6.0, s) + tap(t, sm, uv + dir / 6.0, s));
    float3 b = a * 0.5 + 0.25 * (tap(t, sm, uv - dir * 0.5, s) + tap(t, sm, uv + dir * 0.5, s));
    float lB = fxLuma(b);
    return (lB < lMin || lB > lMax) ? a : b;
}

fragment float4 fs_feedback(VOut in [[stage_in]], constant PostU& P [[buffer(0)]],
                            texture2d<float> scene [[texture(0)]], texture2d<float> prev [[texture(1)]],
                            sampler s0 [[sampler(0)]], sampler s1 [[sampler(1)]]) {
    float3 cur = fxaa(scene, s0, in.uv, P.src0);
    float trails = P.p0.x, zoom = P.p0.y, ang = P.p0.z, aspect = P.p0.w;
    float2 c = in.uv - 0.5;
    c.x *= aspect;
    c = rot(ang) * c * (1.0 - zoom);
    c.x /= aspect;
    float2 uvp = c + 0.5;
    float3 old = (all(uvp >= 0.0) && all(uvp <= 1.0)) ? tap(prev, s1, uvp, P.src1) : float3(0.0);
    // Trails keep only what is brighter than the new frame (light streaks, not a muddy blur),
    // plus a little plain blending, which also averages the volumetric dither.
    float3 o = cur + max(old * trails - cur, 0.0) * 0.85;
    o = mix(o, old, 0.12 * trails);
    if (any(isnan(o)) || any(isinf(o))) o = float3(0.0);
    return float4(min(o, float3(64.0)), 1.0);
}

// 13-tap downsample (two box rings), used for every level of the bloom pyramid.
static float3 down13(texture2d<float> t, sampler sm, float2 uv, float4 s, thread float3& centre) {
    float2 d = s.zw / s.xy; // one source texel, in 0..1 active-region units
    float3 a = tap(t, sm, uv + d * float2(-2, -2), s), b = tap(t, sm, uv + d * float2(0, -2), s), c = tap(t, sm, uv + d * float2(2, -2), s);
    float3 e = tap(t, sm, uv + d * float2(-2, 0), s), f = tap(t, sm, uv, s), g = tap(t, sm, uv + d * float2(2, 0), s);
    float3 h = tap(t, sm, uv + d * float2(-2, 2), s), i = tap(t, sm, uv + d * float2(0, 2), s), j = tap(t, sm, uv + d * float2(2, 2), s);
    float3 k = tap(t, sm, uv + d * float2(-1, -1), s), l = tap(t, sm, uv + d * float2(1, -1), s);
    float3 m = tap(t, sm, uv + d * float2(-1, 1), s), n = tap(t, sm, uv + d * float2(1, 1), s);
    centre = f;
    return (a + c + h + j) * 0.03125 + (b + e + g + i) * 0.0625 + f * 0.125 + (k + l + m + n) * 0.125;
}

fragment float4 fs_prefilter(VOut in [[stage_in]], constant PostU& P [[buffer(0)]],
                             texture2d<float> src [[texture(0)]], sampler s0 [[sampler(0)]]) {
    float3 centre;
    float3 c = down13(src, s0, in.uv, P.src0, centre);
    // Clamp fireflies (single very hot pixels would bloom into flickering blobs), then a soft knee.
    c = min(c, float3(24.0));
    float thr = P.p0.x, knee = P.p0.y;
    float br = max(c.r, max(c.g, c.b));
    float soft = clamp(br - thr + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contrib = max(soft, br - thr) / max(br, 1e-4);
    return float4(c * contrib, 1.0);
}

fragment float4 fs_down(VOut in [[stage_in]], constant PostU& P [[buffer(0)]],
                        texture2d<float> src [[texture(0)]], sampler s0 [[sampler(0)]]) {
    float3 centre;
    return float4(down13(src, s0, in.uv, P.src0, centre), 1.0);
}

fragment float4 fs_up(VOut in [[stage_in]], constant PostU& P [[buffer(0)]],
                      texture2d<float> fine [[texture(0)]], texture2d<float> coarse [[texture(1)]],
                      sampler s0 [[sampler(0)]], sampler s1 [[sampler(1)]]) {
    float2 d = P.src1.zw / P.src1.xy;
    float3 s = tap(coarse, s1, in.uv, P.src1) * 4.0;
    s += (tap(coarse, s1, in.uv + d * float2(-1, 0), P.src1) + tap(coarse, s1, in.uv + d * float2(1, 0), P.src1) +
          tap(coarse, s1, in.uv + d * float2(0, -1), P.src1) + tap(coarse, s1, in.uv + d * float2(0, 1), P.src1)) * 2.0;
    s += tap(coarse, s1, in.uv + d * float2(-1, -1), P.src1) + tap(coarse, s1, in.uv + d * float2(1, -1), P.src1) +
         tap(coarse, s1, in.uv + d * float2(-1, 1), P.src1) + tap(coarse, s1, in.uv + d * float2(1, 1), P.src1);
    return float4(tap(fine, s0, in.uv, P.src0) + s / 16.0 * P.p0.x, 1.0);
}

static float3 aces(float3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }

fragment float4 fs_final(VOut in [[stage_in]], constant PostU& P [[buffer(0)]],
                         texture2d<float> img [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                         sampler s0 [[sampler(0)]], sampler s1 [[sampler(1)]]) {
    float bloomAmt = P.p0.x, chroma = P.p0.y, exposure = P.p0.z, flash = P.p0.w;
    float grain = P.p1.x, time = P.p1.y;
    float2 res = P.p1.zw;
    float2 uv = in.uv;
    float2 dc = uv - 0.5;
    float r2 = dot(dc, dc);

    // Chromatic aberration: radial, stronger toward the edges.
    float2 off = dc * chroma * 0.012 * (0.3 + r2 * 3.0);
    float3 col;
    col.r = tap(img, s0, uv + off, P.src0).r;
    col.g = tap(img, s0, uv, P.src0).g;
    col.b = tap(img, s0, uv - off, P.src0).b;
    float3 bl;
    bl.r = tap(bloom, s1, uv + off * 1.5, P.src1).r;
    bl.g = tap(bloom, s1, uv, P.src1).g;
    bl.b = tap(bloom, s1, uv - off * 1.5, P.src1).b;
    col += bl * bloomAmt * 0.1;

    // Flash: exposure push plus a white-out that bloom has already spread.
    // Strong enough to hide a swap underneath, but the new scene still shows through on the cut frame.
    col *= exposure * (1.0 + 0.5 * flash);
    col += flash * flash * float3(0.3, 0.29, 0.28);

    col = aces(col);
    // A little extra saturation after the tonemap keeps neon colours from greying out.
    float l = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = max(mix(float3(l), col, 1.12), 0.0);
    col *= 1.0 - 0.45 * pow(r2 * 2.0, 1.4);       // vignette

    col = pow(col, float3(1.0 / 2.2));
    float2 px = uv * res;
    float n = hash21(px + fract(time * 13.7) * 117.0) - 0.5;
    col += n * grain + (hash21(px * 1.37 + 3.1) - 0.5) / 255.0;  // film grain + dither
    return float4(sat(col.r), sat(col.g), sat(col.b), 1.0);
}

// Calibration display: the whole screen flashes white on each beat (sharp attack, ~80 ms
// decay) and a bar sweeps across once per beat, so flash vs. click timing is easy to judge.
fragment float4 fs_calibrate(VOut in [[stage_in]], constant PostU& P [[buffer(0)]]) {
    float beatPhase = P.p0.x, bpm = max(P.p0.y, 1.0);
    float since = beatPhase * 60.0 / bpm;
    float3 col = float3(exp(-since / 0.08));
    col += float3(0.1, 0.6, 1.0) * step(abs(in.uv.x - beatPhase), 0.004) * step(0.9, in.uv.y);
    col = mix(col, float3(0.15), step(in.uv.y, 0.02) * step(0.5, fract(in.uv.x * 4.0)));
    return float4(col, 1.0);
}
