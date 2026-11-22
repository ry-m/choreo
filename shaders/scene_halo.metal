// Scene "Bar Halo": the classic bar analyser as a monument. 64 bars (32 bands, mirrored) stand in a
// ring on a black mirror floor, lit from inside as segmented LEDs, each with a floating peak-hold cap
// that falls slowly; a bass orb hovers in the middle. Variants: one ring, double ring (inner ring
// shows the spectrum ~0.5 s ago), a spiral, and the flat wall of the old-school screen.
// Camera: orbit; section changes move it (low / overhead / close / far).

constant float HALO_N = 64.0;

struct HaloHit { float d; float id; float kind; };   // kind: 0 bar, 1 cap, 2 orb

static float2 haloBand(texture2d<float> hist, sampler hs, constant Frame& u, float id, float age) {
    float band = id < 32.0 ? id : 63.0 - id;           // mirrored: bass meets bass, treble meets treble
    float4 s = hist.sample(hs, float2((band + 0.5) / HIST_COLS, histV(u, age)));
    return s.rg;                                        // level, peak cap
}

static HaloHit haloMap(float3 p, texture2d<float> hist, sampler hs, constant Frame& u) {
    int variant = int(floor(u.look.x + 0.5)) % 4;
    float H = 3.2 * (1.0 + 0.3 * u.dyn.y);
    HaloHit h; h.d = 1e3; h.id = 0.0; h.kind = 0.0;

    // Bass orb.
    float orb = length(p - float3(0.0, 1.3 + 0.2 * u.rhythm.z, 0.0)) - (0.55 + 0.35 * u.spec.x + 0.15 * u.hits.x);
    h.d = orb; h.kind = 2.0;

    for (int ring = 0; ring < (variant == 1 ? 2 : 1); ++ring) {
        float3 q;
        float id;
        float R = (ring == 0 ? 4.2 : 2.6) + 0.25 * u.spec.x;
        float age = ring == 0 ? 0.0 : 0.5;
        if (variant == 3) {
            // Flat wall: bars side by side along x.
            float w = 0.26;
            id = clamp(floor(p.x / w + HALO_N * 0.5), 0.0, HALO_N - 1.0);
            q = float3(p.x - (id - HALO_N * 0.5 + 0.5) * w, p.y, p.z);
        } else {
            float sa = TAU / HALO_N;
            float a = atan2(p.z, p.x) + (ring == 1 ? sa * 0.5 : 0.0) + u.motion.y * (ring == 0 ? 0.15 : -0.25);
            id = floor(modf1(a, TAU) / sa);
            float al = modf1(a, sa) - sa * 0.5;
            float r = length(p.xz);
            if (variant == 2) R += id / HALO_N * 2.5 - 1.0;   // spiral
            q = float3(r * cos(al) - R, p.y, r * sin(al));
        }
        float2 lv = haloBand(hist, hs, u, id, age);
        float bh = 0.06 + lv.x * lv.x * H;
        float wid = variant == 3 ? 0.1 : 0.11 * (R / 4.2);
        float bar = sdBox(q - float3(0.0, bh * 0.5, 0.0), float3(0.09, bh * 0.5, wid * 0.8));
        float capY = 0.06 + lv.y * lv.y * H + 0.12;
        float cap = sdBox(q - float3(0.0, capY, 0.0), float3(0.1, 0.02, wid * 0.8 + 0.01));
        if (bar < h.d) { h.d = bar; h.id = id; h.kind = 0.0; }
        if (cap < h.d) { h.d = cap; h.id = id; h.kind = 1.0; }
    }
    return h;
}

static float3 haloShade(float3 p, float3 rd, HaloHit h, texture2d<float> hist, sampler hs, constant Frame& u) {
    float hue = u.look.z;
    float H = 3.2 * (1.0 + 0.3 * u.dyn.y);
    if (h.kind > 1.5) {
        // Orb: emissive core, brighter rim, pulsing with the kick.
        float3 n = normalize(p - float3(0.0, 1.3 + 0.2 * u.rhythm.z, 0.0));
        float rim = pow(1.0 - sat(dot(n, -rd)), 2.0);
        return pal(u, 0.25 + hue) * (0.6 + 2.5 * u.hits.x + 1.2 * u.spec.x) * (0.4 + rim * 1.6);
    }
    float band = h.id < 32.0 ? h.id : 63.0 - h.id;
    if (h.kind > 0.5) return mix(pal(u, 0.48 + hue), float3(1.0), 0.5) * (0.9 + 0.8 * u.rhythm.z);  // peak cap
    // LED segments: colour climbs the palette with height, gaps between segments.
    float y = p.y / H;
    float seg = step(0.22, fract(p.y * 7.0));
    float3 c = pal(u, y * 0.5 + band * 0.004 + hue);
    return c * seg * (0.6 + 0.6 * u.rhythm.z + 0.8 * u.hits.x) + c * 0.03;
}

static float haloMarch(float3 ro, float3 rd, float tMax, int steps, texture2d<float> hist, sampler hs, constant Frame& u,
                       thread HaloHit& h, thread float& glow) {
    float t = 0.0;
    for (int i = 0; i < steps; ++i) {
        float3 p = ro + rd * t;
        h = haloMap(p, hist, hs, u);
        glow += exp(-h.d * 12.0) * 0.012;
        if (h.d < 0.001 * (1.0 + t)) return t;
        t += h.d * 0.85;
        if (t > tMax) break;
    }
    return -1.0;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS) {
    float2 uv = screenUV(in, u);
    float hue = u.look.z;
    int variant = int(floor(u.look.x + 0.5)) % 4;

    // Orbit presets: angle offset, height, distance, look-at height.
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 4.2, 9.5, 0.6), P1 = float4(1.2, 9.5, 5.5, 0.0), P2 = float4(2.6, 2.4, 7.0, 1.4), P3 = float4(4.0, 6.0, 12.5, 0.8);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float ang = C.x + u.motion.z * (variant == 3 ? 0.0 : 1.0) - 1.5708;
    float dist = C.z * (1.0 - 0.06 * u.motion.w);
    // The flat wall is always seen from the front (the old screen view), drifting sideways.
    float3 ro = variant == 3 ? float3(sin(u.motion.z * 0.7) * 3.0, 1.6 + 0.6 * C.y / 9.5, -11.0 * (1.0 - 0.06 * u.motion.w))
                             : float3(cos(ang) * dist, C.y, sin(ang) * dist);
    float3 ta = variant == 3 ? float3(0.0, 1.5, 0.0) : float3(0.0, C.w, 0.0);
    float3x3 cam = lookAt(ro, ta, u.cam.z * 0.2);
    float3 rd = normalize(cam * float3(uv, 1.5 - 0.25 * u.cam.w));

    // Background: deep gradient with a faint ring of light behind the bars.
    float3 col = pal(u, 0.7 + hue) * 0.015 * (1.0 + 2.0 * sat(rd.y + 0.2));

    float glow = 0.0;
    HaloHit h;
    float tFloor = rd.y < 0.0 ? -ro.y / rd.y : 1e3;
    float t = haloMarch(ro, rd, min(tFloor, 40.0), 90, hist, hs, u, h, glow);
    if (t > 0.0) {
        col = haloShade(ro + rd * t, rd, h, hist, hs, u);
    } else if (tFloor < 1e3) {
        // Black mirror floor: reflect the bars, with a fine radial grid and distance fade.
        float3 p = ro + rd * tFloor;
        float3 rr = reflect(rd, float3(0.0, 1.0, 0.0));
        float g2 = 0.0;
        HaloHit hr;
        float tr = haloMarch(p + rr * 0.01, rr, 20.0, 48, hist, hs, u, hr, g2);
        float fres = 0.25 + 0.75 * pow(1.0 - sat(-rd.y), 4.0);
        float3 refl = tr > 0.0 ? haloShade(p + rr * tr, rr, hr, hist, hs, u) : float3(0.0);
        float r = length(p.xz);
        float dr = abs(fract(r * 0.5 + 0.5) - 0.5) * 2.0;     // distance to the nearest ring (every 2 units)
        float gl = 1.0 - smoothstep(0.015, 0.015 + fwidth(r) * 1.5, dr);
        float3 grid = pal(u, 0.55 + hue) * gl * 0.15 * (0.4 + u.rhythm.z) * exp(-r * 0.08);
        col = refl * fres * 0.7 + grid + pal(u, 0.25 + hue) * exp(-r * 0.6) * 0.15 * (0.5 + u.spec.x);
        glow += g2 * 0.4;
    }
    col += pal(u, 0.35 + hue) * glow * (0.5 + u.spec.w);
    return float4(col, 1.0);
}
