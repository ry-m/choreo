// Scene "Prism Cathedral": a cluster of quartz-like glass crystals floating in a dark nave of light.
// The glass refracts (with RGB dispersion) and reflects a procedural environment of light windows.
//   kick   -> the core pulses, windows and skylight flare
//   snare  -> light bands sweep through the haze
//   voice  -> (sustained mids) a heart of light glows inside the core crystal
//   hats / air -> glints run over the facets; stars twinkle
//   bass   -> the core breathes; lifts -> the cluster shatters outward
// Some crystals are clear, some frosted (etched, scattering) and some milky (veiled inclusions);
// tints alternate between the primary and accent palettes.
// Remix genes: 0 symmetry (6-12), 1 crystal proportions, 2 outer shard ring, 3 frost / milk share,
// 4 dispersion, 5 core (single / triple cluster), 6 orbit direction, 7 window count.
// Camera: slow orbit; a step around the cluster every bar; section changes move to new presets.

// Quartz crystal: hexagonal prism with pyramidal tips, axis along y.
static float sdCrystal(float3 q, float r, float h) {
    float2 a = abs(q.xz);
    float hx = max(a.x * 0.866025 + a.y * 0.5, a.y);
    return max(hx - r, (abs(q.y) - h + hx * 1.6) * 0.53);
}

struct PrismHit { float d; float id; };

// The cluster in three groups (core, mirrored rings, outer shards). The march needs all of them;
// shading only needs the group it hit (normals and the march inside the glass: ~20 evaluations a
// pixel), so each group has its own function. `part`: -1 all, 0 core, 1 rings, 2 shards.
static PrismHit prismMap(float3 p, constant Frame& u, int part = -1) {
    float kick = u.hits.x, shatter = u.fx.z, t = u.res.z;
    float sectors = float(6 + 2 * geneI(u, 0, 4));
    p.xz = rot(t * 0.05 + u.motion.y * 0.15) * p.xz;
    PrismHit h; h.d = 1e3; h.id = 0.0;

    if (part <= 0) {
        // Core: one crystal breathing with kick and bass, or a cluster of three.
        float breathe = 1.0 + 0.12 * kick + 0.05 * u.spec.x;
        float3 c = p;
        c.xy = rot(0.25) * c.xy;
        float core = sdCrystal(c, 0.45 * breathe - 0.03, 1.5 * breathe - 0.03) - 0.03;
        if (gene(u, 5) > 0.55) {
            float3 c2 = p - float3(0.35, -0.2, 0.2);
            c2.xy = rot(-0.6) * c2.xy;
            c2.yz = rot(0.4) * c2.yz;
            float3 c3 = p - float3(-0.3, -0.3, -0.25);
            c3.xy = rot(0.8) * c3.xy;
            c3.xz = rot(0.9) * c3.xz;
            core = min(core, min(sdCrystal(c2, 0.3 * breathe, 1.05 * breathe), sdCrystal(c3, 0.27 * breathe, 0.95 * breathe)) - 0.03);
        }
        h.d = core;
    }

    if (part < 0 || part == 1) {
        // Two mirrored rings of crystals leaning outward (polar repetition around y).
        float prop = 0.75 + 0.5 * gene(u, 1);           // long and thin <-> short and stout
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
        float ring = sdCrystal(q, (0.14 + 0.08 * hs) / sqrt(prop), (0.73 + 0.5 * hs) * prop) - 0.02;
        if (ring < h.d) { h.d = ring; h.id = 1.0 + id + (p.y > 0.0 ? 0.0 : 13.0); }
    }

    if (part < 0 || part == 2) {
        // Outer ring of small shards orbiting the other way.
        float3 o = p;
        o.xz = rot(-t * 0.12 - u.motion.z * 0.5) * o.xz;
        float sb = TAU / (sectors * (1.5 + gene(u, 2)));
        float a2 = atan2(o.z, o.x);
        float id2 = floor((a2 + sb * 0.5) / sb);
        a2 = modf1(a2 + sb * 0.5, sb) - sb * 0.5;
        o.xz = float2(cos(a2), sin(a2)) * length(o.xz);
        float h2 = hash11(id2 * 3.1 + 1.0);
        o -= float3(2.4 + 0.6 * gene(u, 2) + 0.4 * h2 + 2.5 * shatter, (h2 - 0.5) * 1.6, 0.0);
        o.xy = rot(h2 * 3.0 + t * 0.3) * o.xy;
        float shard = sdCrystal(o, 0.06, 0.27 + 0.2 * h2) - 0.01;
        if (shard < h.d) { h.d = shard; h.id = 40.0 + id2; }
    }
    return h;
}
static int prismPart(float id) { return id < 0.5 ? 0 : id < 39.5 ? 1 : 2; }

// Normal by central differences over `e`: about one pixel's footprint at the hit, so a pixel that
// straddles a facet edge gets the average of both faces instead of a random one (no edge sparkle).
static float3 prismNormal(float3 p, constant Frame& u, float e = 0.0015, int part = -1) {
    const float2 k = float2(1.0, -1.0) * e;
    return normalize(k.xyy * prismMap(p + k.xyy, u, part).d + k.yyx * prismMap(p + k.yyx, u, part).d +
                     k.yxy * prismMap(p + k.yxy, u, part).d + k.xxx * prismMap(p + k.xxx, u, part).d);
}

// Palette colours the environment needs, evaluated once per pixel (the environment is sampled up to
// five times per pixel: direct, reflected and three dispersed refractions).
struct PrismCols { float3 ambA, ambB, winA, winB, horizon, sky, band; };

static PrismCols prismCols(constant Frame& u) {
    float hue = u.look.z;
    PrismCols c;
    c.ambA = pal(u, 0.6 + hue);  c.ambB = acc(u, 0.85 + hue);
    c.winA = pal(u, hue);        c.winB = acc(u, 0.3 + hue);
    c.horizon = mix(pal(u, 0.35 + hue), acc(u, 0.1 + hue), 0.35);
    c.sky = pal(u, 0.1 + hue);   c.band = acc(u, 0.8 + hue);
    return c;
}

// The nave: dark space with tall light windows around the horizon (primary and accent), a skylight,
// stars and sweeping light bands. The glass shows all of it refracted and reflected.
static float3 prismEnv(float3 rd, constant Frame& u, PrismCols pc, bool stars = true) {
    float beat = u.rhythm.z, bar = u.rhythm.w, energy = u.dyn.x;
    float3 col = mix(pc.ambA, pc.ambB, sat(rd.y * 0.5 + 0.5)) * (0.004 + 0.012 * (1.0 - abs(rd.y)));
    float ang = atan2(rd.z, rd.x) + u.motion.z * 0.3;
    float nWin = 8.0 + 4.0 * float(geneI(u, 7, 3));
    float w = fract(ang * nWin / TAU);
    float idx = floor(ang * nWin / TAU);
    float win = smoothstep(0.07, 0.035, abs(w - 0.5)) * smoothstep(0.5, 0.3, abs(rd.y - 0.1));
    // Mullions: each window split into panes (texture in the reflections and refractions).
    win *= 0.55 + 0.45 * step(0.12, fract((rd.y - 0.1) * 14.0));
    float hw = hash11(idx + floor(u.res.z * u.dyn.z * 2.0));
    float lit = 0.25 + 0.75 * step(0.5, hw);  // builds flicker windows
    float3 wc = mix(pc.winA, pc.winB, step(0.5, hash11(idx * 1.7 + u.look.y * 5.0)));
    col += wc * win * lit * (1.5 + 3.0 * beat + 2.0 * bar) * (0.5 + energy);
    // Horizon glow (gives the glass something coloured to bend), skylight and a bright key from above.
    col += pc.horizon * exp(-abs(rd.y + 0.05) * 9.0) * (0.12 + 0.25 * energy);
    col += pc.sky * pow(sat(rd.y), 8.0) * (0.6 + 2.0 * u.hits.x);
    col += float3(1.0, 0.95, 0.9) * pow(sat(dot(rd, normalize(float3(0.3, 1.0, 0.2)))), 120.0) * 12.0;
    // Sweeping light bands (lasers through haze) on the snare.
    float band = abs(dot(rd, normalize(float3(sin(u.motion.y), 0.3, cos(u.motion.y)))));
    col += pc.band * exp(-band * 60.0) * (0.5 + 4.0 * u.hits.y);
    // Stars (direct view only: through the glass they would be magnified into blocky dots).
    if (!stars) return col;
    float3 sc = floor(rd * 180.0);
    float st = hash31(sc);
    col += step(0.997, st) * float3(1.0) * (0.6 + 1.5 * u.hits.z + 1.5 * u.bands.w) * smoothstep(0.0, 0.2, rd.y + 0.3);
    return col;
}

// The environment box-filtered over a ray's pixel footprint (dx, dy: how its direction changes to the
// next pixel). Rays that turn fast between pixels (reflection and refraction near facet edges) would
// otherwise alias the thin windows and pane bars into dashed, sparkling lines; only those pay for
// the extra samples.
static float3 prismEnvF(float3 rd, float3 dx, float3 dy, constant Frame& u, PrismCols pc) {
    float3 c = prismEnv(rd, u, pc, false);
    if (length(dx) + length(dy) < 0.05) return c;
    c += prismEnv(normalize(rd + 0.4 * dx), u, pc, false) + prismEnv(normalize(rd - 0.4 * dx), u, pc, false);
    c += prismEnv(normalize(rd + 0.4 * dy), u, pc, false) + prismEnv(normalize(rd - 0.4 * dy), u, pc, false);
    return c * 0.2;
}

// Glass shading at surface point p seen along rd.
static float3 prismShade(float3 p, float3 rd, float id, float t, float px, constant Frame& u, PrismCols pc, NZP) {
    float kick = u.hits.x, hue = u.look.z;
    int part = prismPart(id);
    float3 n = prismNormal(p, u, max(0.0015, px * t * 0.7), part);
    // Crystal kind (per crystal): 0 clear, 1 frosted, 2 milky. The core stays clear.
    float hk = hash11(id * 3.7 + u.look.y * 17.0);
    float share = 0.15 + 0.55 * gene(u, 3);
    int kind = id < 0.5 ? 0 : hk < share * 0.5 ? 1 : hk < share ? 2 : 0;
    // Surface texture: Worley etching on every face, much stronger on frosted crystals.
    float4 tx = nz4(NZ, p * 4.0 + id * 1.3);
    float etch = 1.0 - smoothstep(0.0, 0.06, tx.a);
    if (kind == 1) n = normalize(n + (tx.rgb - 0.5) * 0.5);

    float cosi = sat(dot(-rd, n));
    float fres = 0.04 + 0.96 * pow(1.0 - cosi, 5.0);
    float3 rr = reflect(rd, n);
    float3 refl = prismEnvF(rr, dfdx(rr), dfdy(rr), u, pc);

    // Refraction: one march through the crystal to find its thickness and exit normal, then
    // three exit rays with slightly different indices (dispersion) into the environment.
    float disp = (0.015 + 0.03 * gene(u, 4)) * (1.0 + u.dyn.y);
    float3 rdi = refract(rd, n, 1.0 / 1.47);
    float3 q = p - n * 0.01;
    float ti = 0.0;
    for (int j = 0; j < 18; ++j) {
        float d = -prismMap(q + rdi * ti, u, part).d;
        if (d < 0.001) break;
        ti += max(d, 0.012);
    }
    // Grazing hits near an edge measure almost no glass and would print thin bright dashed lines;
    // give the glass a minimum thickness so they shade like their neighbours.
    ti = max(ti, 0.12);
    float3 ne = -prismNormal(q + rdi * ti, u, max(0.0015, px * t * 0.7), part);
    // Pixel footprint of the refracted rays (measured on the middle wavelength).
    float3 rim = refract(rdi, ne, 1.47);
    if (dot(rim, rim) < 0.01) rim = reflect(rdi, ne);
    float3 rdx = dfdx(rim), rdy = dfdy(rim);
    float3 tr;
    for (int c = 0; c < 3; ++c) {
        float ior = 1.47 + (float(c) - 1.0) * disp;
        float3 ri = refract(rd, n, 1.0 / ior);
        float3 ro2 = refract(ri, ne, ior);
        if (dot(ro2, ro2) < 0.01) ro2 = reflect(ri, ne);  // total internal reflection
        float3 e = prismEnvF(ro2, rdx, rdy, u, pc);
        tr[c] = c == 0 ? e.r : c == 1 ? e.g : e.b;
    }
    tr = min(tr, float3(2.5));   // no fireflies from refracted key light
    // Coloured glass: absorption by thickness, tinted per crystal from the primary or accent palette.
    float3 tint = hk > 0.5 ? pal(u, id * 0.071 + hue + 0.15) : acc(u, id * 0.053 + hue);
    tint *= tint;                                   // squared: deeper, more saturated glass
    float3 absorb = exp(-ti * (1.1 - tint) * 2.2);
    float3 body = tr * absorb;
    if (kind == 1) body = mix(body, (pc.horizon * 0.3 + tr * 0.3) * (tint + 0.1), 0.6);   // frosted: scattered, softer
    if (kind == 2) {
        // Milky quartz: veils of inclusions inside, lit by the nave.
        float veil = nfbm(NZ, (q + rdi * ti * 0.5) * 3.0 + id, 3);
        body = mix(body, tint * (0.15 + 0.6 * pc.horizon) , sat((veil - 0.35) * 2.0) * sat(ti * 1.5));
    }
    // The voice lights a heart inside the core crystal(s).
    if (id < 0.5) {
        float3 heart = mix(pc.sky, pc.winB, 0.5);
        body += heart * heart * exp(-ti * 1.5) * (0.05 + 1.0 * u.bands.z * u.bands.z) * (0.6 + 0.8 * kick);
    }
    float3 col = mix(body, refl, fres);
    // Edges catch light: a soft rim toward grazing angles, brighter on the kick.
    col += (hk > 0.5 ? acc(u, id * 0.13 + 0.5) : pal(u, id * 0.13 + 0.5)) * pow(1.0 - cosi, 4.0) * (0.25 + 1.2 * kick);
    // Etched lines catch the light; hats and air make glints run over the facets.
    col += pc.winA * etch * (kind == 1 ? 0.25 : 0.06) * (0.5 + u.dyn.x);
    // (texture coordinates scaled down so a glint spans several pixels; a soft threshold, not a step)
    float gl = nz4(NZ, p * 1.3 + id * 2.1).g;
    float glint = smoothstep(0.78 - 0.06 * u.bands.w, 0.9, gl) * pow(sat(dot(reflect(rd, n), normalize(float3(0.3, 1.0, 0.2)))), 4.0) * 0.5;
    col += float3(1.0) * glint * (0.5 + 6.0 * u.hits.z + 4.0 * u.bands.w);
    return mix(col, prismEnv(rd, u, pc) * 0.5, sat(t / 22.0));
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS, NOISE_ARGS) {
    float2 uv = screenUV(in, u);
    float flash = u.fx.x, kick = u.hits.x, time = u.res.z;
    PrismCols pc = prismCols(u);

    // Orbit camera: four presets (angle offset, height, distance), eased between on section changes;
    // a step around the cluster every bar (direction from a gene), a two-bar rise and fall, and drift.
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 0.5, 5.2, 0.0), P1 = float4(1.6, 2.4, 6.4, 0.0), P2 = float4(3.4, -1.3, 4.4, 0.0), P3 = float4(4.9, 1.0, 3.5, 0.0);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float bars = u.hist.z, dir = gene(u, 6) < 0.5 ? -1.0 : 1.0;
    float ang = C.x + u.motion.z + dir * 0.4 * bars + 0.15 * sin(time * 0.17);
    float dist = C.z * (1.0 - 0.08 * u.motion.w - 0.04 * u.rhythm.z) * (1.0 + 0.15 * u.fx.z) * (1.0 + 0.08 * sin(bars * 1.1 + time * 0.1));
    float3 ro = float3(cos(ang) * dist, C.y + 0.2 * sin(time * 0.2) + 0.5 * sin(bars * 1.5708) * (0.4 + 0.6 * u.dyn.y), sin(ang) * dist);
    float3 ta = float3(0.15 * sin(time * 0.23), 0.1 * sin(time * 0.3), 0.15 * cos(time * 0.19));
    float3x3 cam = lookAt(ro, ta, 0.15 * sin(time * 0.13) + u.cam.z * 0.3);
    float fov = 1.5 - 0.25 * u.cam.w;
    float3 rd = normalize(cam * float3(uv, fov));

    // March with a pixel-sized cone: remember the closest near miss, so silhouettes get partial
    // coverage instead of a hard staircase.
    const float px = 1.25 / (u.res.y * fov);   // angular size of a pixel (a bit more, for softness)
    float t = 0.0, glow = 0.0;
    float bestR = 1e9, bestT = 0.0, bestId = 0.0;
    PrismHit h;
    bool hit = false;
    for (int i = 0; i < 90; ++i) {
        float3 p = ro + rd * t;
        h = prismMap(p, u);
        // Light trapped around the core: glow near it, brighter on kicks.
        glow += exp(-length(p) * 2.2) * 0.02;
        if (h.d < 0.0006 * (1.0 + t)) { hit = true; break; }
        float r = h.d / (px * max(t, 0.05));
        if (r < bestR && t > 0.05) { bestR = r; bestT = t; bestId = h.id; }
        t += h.d * 0.9;
        if (t > 22.0) break;
    }

    float3 bg = prismEnv(rd, u, pc) * 0.6;
    float3 col = bg;
    if (hit || bestR < 1.0) {
        // One call site for hits and near misses (within a pixel: shade the surface point closest to
        // the ray, weighted by coverage), so neighbouring pixels share it and its pixel derivatives hold.
        float3 sp; float sid, st, cover = 1.0;
        if (hit) {
            for (int i = 0; i < 2; ++i) t += prismMap(ro + rd * t, u).d;   // converge onto the surface
            sp = ro + rd * t; sid = h.id; st = t;
        } else {
            sp = ro + rd * bestT;
            sp -= prismNormal(sp, u) * prismMap(sp, u).d;
            sid = bestId; st = bestT;
            cover = 1.0 - smoothstep(0.0, 1.0, bestR);
        }
        col = mix(bg, prismShade(sp, rd, sid, st, px, u, pc, NZ), cover);
    }
    col += mix(pc.sky, pc.winB, 0.5 + 0.5 * sin(time * 0.3)) * glow * (1.0 + 6.0 * kick + 1.5 * flash + 2.0 * u.bands.z);

    // Shockwave ring on hits.
    float R = u.fx.y * 7.0;
    col += pc.band * ringGlow(ro, rd, float3(0.0), R, 0.02, hit ? t : 1e3) * 6.0 * exp(-u.fx.y * 1.5);
    return float4(col, 1.0);
}
