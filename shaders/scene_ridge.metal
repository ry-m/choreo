// Scene "Spectral Ridge": the old-school 3D spectrogram waterfall, rebuilt as a landscape. The last
// ~4.3 s of the spectrum is a terrain (z = time, now at the front; x = frequency, bass in the middle
// mirrored outward, or low-to-high in one variant), drawn as glowing ridge lines on an opaque dark
// surface (hidden lines) under a pulsing horizon ring. Kicks light the newest ridge, builds raise it.
// Camera: low flight over the front edge looking back in time; presets give overview / side / close.

constant float RIDGE_LEN = 26.0;   // z extent of the history
constant float RIDGE_W = 7.5;      // half width (x) of the spectrum

static float ridgeFreq(constant Frame& u, float x, thread float& edge) {
    int variant = int(floor(u.look.x + 0.5)) % 4;
    float f = variant == 1 ? (x / RIDGE_W + 1.0) * 0.5   // classic: low left, high right
                           : abs(x) / RIDGE_W;           // mirrored: bass in the middle
    edge = variant == 1 ? smoothstep(1.0, 0.95, abs(x) / RIDGE_W) : smoothstep(1.0, 0.9, f);
    return sat(f);
}

static float ridgeH(texture2d<float> hist, sampler hs, constant Frame& u, float2 xz) {
    float edge;
    float f = ridgeFreq(u, xz.x, edge);
    float age = max(xz.y, 0.0) / RIDGE_LEN * (HIST_ROWS - 4.0) / u.hist.y;
    float v = histSpec(hist, hs, u, pow(f, 0.85), age).r;
    float h = v * v * (2.0 + 1.2 * u.dyn.y + 1.0 * u.dyn.z) * edge;
    return h * smoothstep(-0.6, 0.2, xz.y) * smoothstep(RIDGE_LEN, RIDGE_LEN - 4.0, xz.y);
}

static float3 ridgeSky(float3 rd, constant Frame& u) {
    float hue = u.look.z;
    float3 col = pal(u, 0.65 + rd.y * 0.4 + hue) * 0.03 * (1.0 - sat(rd.y));
    // Horizon ring: a thin circle low in the sky ahead, pulsing with the bass and kick.
    float2 c = float2(rd.x, rd.y - 0.08);
    float R = 0.32 + 0.03 * u.spec.x + 0.02 * u.hits.x;
    float ring = abs(length(c) - R);
    col += pal(u, 0.15 + hue) * (0.004 / (0.004 + ring * ring * 300.0)) * (1.0 + 2.5 * u.hits.x) * step(-0.02, rd.y);
    col += pal(u, 0.1 + hue) * exp(-length(c) * 4.0) * 0.25 * (0.5 + u.spec.x);
    col += pal(u, 0.8 + hue) * exp(-abs(rd.y) * 30.0) * 0.12;   // horizon haze
    float3 sc = floor(rd * 260.0);
    col += step(0.998, hash31(sc)) * step(0.05, rd.y) * (0.4 + 1.5 * u.hits.z);
    return col;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS) {
    float2 uv = screenUV(in, u);
    float hue = u.look.z, kick = u.hits.x;

    // Camera presets: position.xyz and look-at z.
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 2.6, -5.5, 10.0), P1 = float4(0.0, 8.0, -4.0, 9.0), P2 = float4(-10.0, 3.2, 6.0, 9.0), P3 = float4(2.0, 1.1, -2.0, 6.0);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float sway = sin(u.motion.z * 2.0) * 0.8;
    float3 ro = float3(C.x + sway, C.y - 0.25 * u.motion.w, C.z);
    float3 ta = float3(sway * 0.3, 0.3, C.w);
    float3x3 cam = lookAt(ro, ta, u.cam.z * 0.25);
    float fov = 1.45 - 0.25 * u.cam.w;
    float3 rd = normalize(cam * float3(uv, fov));

    float3 col = ridgeSky(rd, u);
    // Heightfield march: conservative steps (slopes can be steep), then refine.
    const float hMax = 4.5;
    float t = 0.05, tPrev = 0.05;
    bool hit = false;
    if (ro.y > hMax && rd.y >= 0.0) t = 1e3;
    for (int i = 0; i < 110 && t < 60.0; ++i) {
        float3 p = ro + rd * t;
        if (p.y > hMax && rd.y >= 0.0) break;
        float dy = p.y - ridgeH(hist, hs, u, p.xz);
        if (dy < 0.002 * t) { hit = true; break; }
        tPrev = t;
        t += max(dy * 0.45, 0.01 + t * 0.006);
    }
    if (hit) {
        for (int i = 0; i < 5; ++i) {       // bisect between the last point above and the first below
            float tm = 0.5 * (t + tPrev);
            float3 p = ro + rd * tm;
            if (p.y > ridgeH(hist, hs, u, p.xz)) tPrev = tm; else t = tm;
        }
        float3 p = ro + rd * t;
        float h = ridgeH(hist, hs, u, p.xz);
        const float e = 0.04;
        float3 n = normalize(float3(h - ridgeH(hist, hs, u, p.xz + float2(e, 0.0)), e, h - ridgeH(hist, hs, u, p.xz + float2(0.0, e))));
        float edge;
        float f = ridgeFreq(u, p.x, edge);
        float age = max(p.z, 0.0) / RIDGE_LEN;

        // Ridge lines along constant time (the waterfall rows), faint lines along frequency.
        const float sp = 0.38;
        float dz = abs(fract(p.z / sp + 0.5) - 0.5) * sp;
        float aa = fwidth(p.z) + 0.004;
        float line = 1.0 - smoothstep(0.012, 0.012 + aa, dz);
        float dx = abs(fract(p.x / 0.6 + 0.5) - 0.5) * 0.6;
        float lineX = (1.0 - smoothstep(0.004, 0.004 + fwidth(p.x) + 0.004, dx)) * 0.06;

        float3 lc = pal(u, f * 0.9 + age * 0.3 + hue);
        float glow = 0.3 + 1.6 * h + 1.5 * u.rhythm.z * exp(-age * 6.0) + 2.5 * kick * exp(-age * 12.0);
        float3 surf = pal(u, 0.6 + hue) * 0.015 * (0.3 + 0.7 * sat(n.y));      // dark, faintly lit body
        surf += lc * (line + lineX) * glow * (1.0 - 0.6 * age);
        surf += lc * h * h * 0.025;                                            // peaks glow faintly from within
        // The newest edge (now) burns brightest.
        surf += lc * exp(-max(p.z, 0.0) * 9.0) * (0.5 + 1.2 * u.spec.w) * smoothstep(-0.3, 0.0, p.z);
        float fog = exp(-max(t - 6.0, 0.0) * 0.045);
        col = mix(col, surf, fog);
    }
    return float4(col, 1.0);
}
