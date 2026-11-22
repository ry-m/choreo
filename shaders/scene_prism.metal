// Scene "Prism Cathedral": a cluster of quartz-like glass crystals floating in a dark nave of light.
// The glass refracts (with RGB dispersion) and reflects a procedural environment of light windows
// that pulse with the beat; lifts shatter the cluster outward, kicks pulse the core.
// Camera: slow orbit; section changes move to a new orbit angle/height.

// Quartz crystal: hexagonal prism with pyramidal tips, axis along y.
static float sdCrystal(float3 q, float r, float h) {
    float2 a = abs(q.xz);
    float hx = max(a.x * 0.866025 + a.y * 0.5, a.y);
    return max(hx - r, (abs(q.y) - h + hx * 1.6) * 0.53);
}

struct PrismHit { float d; float id; };

static PrismHit prismMap(float3 p, constant Frame& u) {
    float kick = u.hits.x, shatter = u.fx.z, t = u.res.z;
    int variant = int(floor(u.look.x + 0.5));
    float sectors = float(6 + 2 * (variant % 3));
    p.xz = rot(t * 0.05 + u.motion.y * 0.15) * p.xz;

    // Core crystal, breathing with the kick.
    float3 c = p;
    c.xy = rot(0.25) * c.xy;
    float core = sdCrystal(c, 0.45 * (1.0 + 0.12 * kick), 1.5 * (1.0 + 0.1 * kick));
    PrismHit h; h.d = core; h.id = 0.0;

    // Two mirrored rings of crystals leaning outward (polar repetition around y).
    float3 q = p;
    q.y = abs(q.y);
    float sa = TAU / sectors;
    float ang = atan2(q.z, q.x);
    float id = floor((ang + sa * 0.5) / sa);
    ang = modf1(ang + sa * 0.5, sa) - sa * 0.5;
    float r = length(q.xz);
    q.xz = float2(cos(ang), sin(ang)) * r;
    float hs = hash11(id + 7.0 * (p.y > 0.0 ? 1.0 : 0.0));
    float R = 0.9 + 0.35 * hs + 1.6 * shatter * (0.6 + hs);
    q -= float3(R, 0.35 + 0.3 * hs + 0.8 * shatter, 0.0);
    q.xy = rot(-0.55 - 0.25 * hs - 1.2 * shatter * hs) * q.xy;
    q.yz = rot(shatter * (hs - 0.5) * 2.0) * q.yz;
    float ring = sdCrystal(q, 0.16 + 0.08 * hs, 0.75 + 0.5 * hs);
    if (ring < h.d) { h.d = ring; h.id = 1.0 + id; }

    // Outer ring of small shards orbiting the other way.
    float3 o = p;
    o.xz = rot(-t * 0.12 - u.motion.z * 0.5) * o.xz;
    float sb = TAU / (sectors * 2.0);
    float a2 = atan2(o.z, o.x);
    float id2 = floor((a2 + sb * 0.5) / sb);
    a2 = modf1(a2 + sb * 0.5, sb) - sb * 0.5;
    o.xz = float2(cos(a2), sin(a2)) * length(o.xz);
    float h2 = hash11(id2 * 3.1 + 1.0);
    o -= float3(2.6 + 0.4 * h2 + 2.5 * shatter, (h2 - 0.5) * 1.6, 0.0);
    o.xy = rot(h2 * 3.0 + t * 0.3) * o.xy;
    float shard = sdCrystal(o, 0.07, 0.28 + 0.2 * h2);
    if (shard < h.d) { h.d = shard; h.id = 40.0 + id2; }
    return h;
}

static float3 prismNormal(float3 p, constant Frame& u) {
    const float2 k = float2(1.0, -1.0) * 0.0015;
    return normalize(k.xyy * prismMap(p + k.xyy, u).d + k.yyx * prismMap(p + k.yyx, u).d +
                     k.yxy * prismMap(p + k.yxy, u).d + k.xxx * prismMap(p + k.xxx, u).d);
}

// The nave: dark violet space with tall light windows around the horizon, a skylight, stars and
// sweeping light bands. The glass shows all of it refracted and reflected.
static float3 prismEnv(float3 rd, constant Frame& u) {
    float beat = u.rhythm.z, bar = u.rhythm.w, energy = u.dyn.x, hue = u.look.z;
    float3 col = pal(u, 0.6 + rd.y * 0.25 + hue) * (0.004 + 0.012 * (1.0 - abs(rd.y)));
    float ang = atan2(rd.z, rd.x) + u.motion.z * 0.3;
    float nWin = 12.0;
    float w = fract(ang * nWin / TAU);
    float idx = floor(ang * nWin / TAU);
    float win = smoothstep(0.07, 0.035, abs(w - 0.5)) * smoothstep(0.5, 0.3, abs(rd.y - 0.1));
    float lit = 0.25 + 0.75 * step(0.5, hash11(idx + floor(u.res.z * u.dyn.z * 2.0)));  // builds flicker windows
    col += pal(u, idx * 0.083 + hue) * win * lit * (1.5 + 3.0 * beat + 2.0 * bar) * (0.5 + energy);
    // Horizon glow (gives the glass something coloured to bend), skylight and a bright key from above.
    col += pal(u, 0.35 + rd.x * 0.2 + hue) * exp(-abs(rd.y + 0.05) * 9.0) * (0.12 + 0.25 * energy);
    col += pal(u, 0.1 + hue) * pow(sat(rd.y), 8.0) * (0.6 + 2.0 * u.hits.x);
    col += float3(1.0, 0.95, 0.9) * pow(sat(dot(rd, normalize(float3(0.3, 1.0, 0.2)))), 120.0) * 12.0;
    // Sweeping light bands (lasers through haze) on the snare.
    float band = abs(dot(rd, normalize(float3(sin(u.motion.y), 0.3, cos(u.motion.y)))));
    col += pal(u, 0.8 + hue) * exp(-band * 60.0) * (0.5 + 4.0 * u.hits.y);
    // Stars.
    float3 sc = floor(rd * 180.0);
    float st = hash31(sc);
    col += step(0.997, st) * float3(1.0) * (0.6 + 1.5 * u.hits.z) * smoothstep(0.0, 0.2, rd.y + 0.3);
    return col;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]]) {
    float2 uv = screenUV(in, u);
    float flash = u.fx.x, kick = u.hits.x;

    // Orbit camera: four presets (angle offset, height, distance), eased between on section changes.
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 0.5, 5.2, 0.0), P1 = float4(1.6, 2.4, 6.4, 0.0), P2 = float4(3.4, -1.3, 4.4, 0.0), P3 = float4(4.9, 1.0, 3.5, 0.0);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float ang = C.x + u.motion.z;
    float dist = C.z * (1.0 - 0.08 * u.motion.w) * (1.0 + 0.15 * u.fx.z);
    float3 ro = float3(cos(ang) * dist, C.y + 0.2 * sin(u.res.z * 0.2), sin(ang) * dist);
    float3 ta = float3(0.0, 0.1 * sin(u.res.z * 0.3), 0.0);
    float3x3 cam = lookAt(ro, ta, 0.15 * sin(u.res.z * 0.13) + u.cam.z * 0.3);
    float fov = 1.5 - 0.25 * u.cam.w;
    float3 rd = normalize(cam * float3(uv, fov));

    float t = 0.0, glow = 0.0;
    PrismHit h;
    bool hit = false;
    for (int i = 0; i < 80; ++i) {
        float3 p = ro + rd * t;
        h = prismMap(p, u);
        // Light trapped around the core: glow near it, brighter on kicks.
        glow += exp(-length(p) * 2.2) * 0.02;
        if (h.d < 0.0012 * (1.0 + t)) { hit = true; break; }
        t += h.d * 0.9;
        if (t > 22.0) break;
    }

    float3 col = prismEnv(rd, u) * 0.6;
    if (hit) {
        float3 p = ro + rd * t;
        float3 n = prismNormal(p, u);
        float cosi = sat(dot(-rd, n));
        float fres = 0.04 + 0.96 * pow(1.0 - cosi, 5.0);
        float3 refl = prismEnv(reflect(rd, n), u);

        // Refraction: one march through the crystal to find its thickness and exit normal, then
        // three exit rays with slightly different indices (dispersion) into the environment.
        float disp = 0.025 + 0.03 * u.dyn.y;
        float3 rdi = refract(rd, n, 1.0 / 1.47);
        float3 q = p - n * 0.004;
        float ti = 0.0;
        for (int j = 0; j < 14; ++j) {
            float d = -prismMap(q + rdi * ti, u).d;
            if (d < 0.002) break;
            ti += max(d, 0.02);
        }
        float3 pe = q + rdi * ti;
        float3 ne = -prismNormal(pe, u);
        float3 tr;
        for (int c = 0; c < 3; ++c) {
            float ior = 1.47 + (float(c) - 1.0) * disp;
            float3 ri = refract(rd, n, 1.0 / ior);
            float3 ro2 = refract(ri, ne, ior);
            if (dot(ro2, ro2) < 0.01) ro2 = reflect(ri, ne);  // total internal reflection
            float3 e = prismEnv(ro2, u);
            tr[c] = c == 0 ? e.r : c == 1 ? e.g : e.b;
        }
        // Coloured glass: absorption by thickness, tinted per crystal from the palette.
        float3 tint = pal(u, h.id * 0.071 + u.look.z + 0.15);
        float3 absorb = exp(-ti * (1.15 - tint) * 1.6);
        col = mix(tr * absorb, refl, fres);
        // Edges catch light: thin bright rim on silhouettes and on the kick.
        col += pal(u, h.id * 0.13 + 0.5) * pow(1.0 - cosi, 3.0) * (0.3 + 1.5 * kick);
        col = mix(col, prismEnv(rd, u) * 0.5, sat(t / 22.0));
    }
    col += pal(u, 0.3 + u.look.z) * glow * (1.0 + 6.0 * kick + 1.5 * flash);

    // Shockwave ring on hits.
    float R = u.fx.y * 7.0;
    col += pal(u, 0.9) * ringGlow(ro, rd, float3(0.0), R, 0.02, hit ? t : 1e3) * 6.0 * exp(-u.fx.y * 1.5);
    return float4(col, 1.0);
}
