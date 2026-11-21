// Scene 0: "Kaleido Tunnel" — raymarched kaleidoscopic fractal corridor with volumetric neon glow.
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 resTime;  // w, h, time, beatPhase
    float4 beat;     // beatPulse, kick, snare, hat
    float4 spec;     // bass, mid, treble, loudness
    float4 misc;     // energyRatio, brightness, bpm, beatCount
    float4 motion;   // travel, twist, hue, flash
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(c, -s, s, c); }
static float  modf1(float x, float y) { return x - y * floor(x / y); }
static float3 palette(float t, float hue) {
    // Cosine palette: neon magenta / cyan / violet family, rotated by hue.
    float3 a = float3(0.55, 0.45, 0.6), b = float3(0.45, 0.45, 0.4);
    float3 c = float3(1.0, 1.0, 1.0),  d = float3(0.85, 0.2, 0.55) + hue;
    return a + b * cos(6.28318 * (c * t + d));
}

struct Hit { float d; float id; };

static Hit map(float3 p, constant Uniforms& u) {
    float kick = u.beat.y, bass = u.spec.x;
    p.xy = rot(p.z * 0.07 + u.motion.y) * p.xy;

    float3 q = p;
    float cell = floor(q.z / 3.0);
    q.z = modf1(q.z, 3.0) - 1.5;

    // Kaleidoscope around the tunnel axis.
    float sectors = 7.0;
    float ang = atan2(q.y, q.x), r = length(q.xy);
    float sa = 6.28318 / sectors;
    ang = modf1(ang + sa * 0.5, sa) - sa * 0.5;
    q.xy = float2(cos(ang), sin(ang)) * r;
    q.x -= 3.2 - 0.6 * bass;

    // Folding IFS: crisp, crystalline structure that breathes with the kick.
    float s = 1.0;
    float3 off = float3(0.7, 1.0, 0.55) * (1.0 + 0.35 * kick);
    for (int i = 0; i < 4; ++i) {
        q = abs(q) - off;
        q.xy = rot(0.6 + 0.1 * sin(cell + u.resTime.z * 0.2)) * q.xy;
        q.xz = rot(0.35) * q.xz;
        q *= 1.45; s *= 1.45;
    }
    float3 bq = abs(q) - float3(0.5, 0.12, 0.5);
    float d = (length(max(bq, 0.0)) + min(max(bq.x, max(bq.y, bq.z)), 0.0)) / s;

    // Central energy filament.
    float fil = length(p.xy + 0.15 * float2(sin(p.z * 1.3), cos(p.z * 1.1))) - (0.03 + 0.08 * kick);
    Hit h; h.d = d; h.id = cell;
    if (fil < d) { h.d = fil; h.id = -1.0; }
    return h;
}

fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 res = u.resTime.xy;
    float2 uv = (in.uv * res - 0.5 * res) / res.y;
    float kick = u.beat.y, snare = u.beat.z, hat = u.beat.w, beatPulse = u.beat.x;
    float hue = u.motion.z, flash = u.motion.w;

    // Lens punch on kick, slight barrel distortion.
    uv *= 1.0 - 0.08 * kick;
    uv *= 1.0 + 0.15 * dot(uv, uv);

    float3 ro = float3(0.0, 0.0, u.motion.x * 2.0);
    float3 rd = normalize(float3(uv, 1.1 - 0.25 * u.spec.w));
    rd.xy = rot(0.1 * sin(u.resTime.z * 0.3)) * rd.xy;

    float t = 0.0, glow = 0.0;
    float3 col = float3(0.0);
    bool hit = false; Hit h;
    for (int i = 0; i < 64; ++i) {
        float3 p = ro + rd * t;
        h = map(p, u);
        float dd = max(abs(h.d), 0.002);
        // Volumetric glow: accumulate light near surfaces, tinted by depth and section.
        float3 gc = h.id < 0.0 ? float3(1.0, 0.9, 1.0) * (0.6 + 2.0 * kick)
                               : palette(h.id * 0.13 + p.z * 0.02 + hue, hue);
        col += gc * (0.012 / (0.02 + dd * dd * 40.0)) * exp(-t * 0.08);
        if (h.d < 0.001) { hit = true; break; }
        t += h.d * 0.85;
        if (t > 30.0) break;   // fog makes anything further invisible anyway
    }
    col *= 0.045 * (0.6 + 1.6 * u.spec.w + 0.8 * beatPulse);

    if (hit) {
        float3 p = ro + rd * t;
        // Tetrahedral normal: 4 SDF taps instead of 6.
        const float2 k = float2(1.0, -1.0) * 0.002;
        float3 n = normalize(k.xyy * map(p + k.xyy, u).d + k.yyx * map(p + k.yyx, u).d +
                             k.yxy * map(p + k.yxy, u).d + k.xxx * map(p + k.xxx, u).d);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
        float3 base = palette(h.id * 0.13 + hue + 0.5, hue);
        col += base * (0.15 + 0.85 * fres) * exp(-t * 0.07) * (0.5 + 1.5 * u.spec.y);
    }

    // Hats: sparkle grain. Snare: chromatic ring. Beat flash.
    float n = fract(sin(dot(in.uv * res + u.resTime.z, float2(12.9898, 78.233))) * 43758.5453);
    col += hat * 0.25 * step(0.985, n) * float3(0.8, 0.9, 1.0);
    float ring = exp(-pow((length(uv) - (1.0 - u.resTime.w) * 1.2) * 18.0, 2.0));
    col += snare * ring * palette(hue + 0.3, hue) * 0.6;
    col += flash * 0.06 * palette(hue + 0.7, hue);

    // Tonemap (ACES-ish), vignette, gamma.
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col *= 1.0 - 0.35 * dot(uv, uv);
    col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));
    return float4(col, 1.0);
}
