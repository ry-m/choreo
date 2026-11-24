// Scene "Ember Bloom": an obsidian heart with glowing lava cracks inside a column of volumetric fire,
// standing on a plain of cracked basalt.
//   kick   -> the core swells, its cracks surge, and a heat ring runs out across the ground (one ring
//             per kick of the last few seconds, read from the music history)
//   snare  -> flame tongues lick outward
//   voice  -> (sustained mids: vocals, leads, pads) the flames grow taller and sway; spirit wisps
//   hats / air -> streaked sparks; bass -> core glow, heat shimmer; builds -> swirl and rise speed;
//   lifts  -> eruption shell
// Remix genes: 0 tongue count, 1 core shape (sphere / rough rock / ring), 2 ground pattern scale,
// 3 how much accent-coloured "chemical" flame, 4 spark density, 5 smoke, 6 swirl, 7 crack scale.
// Camera: low and close, looking up into the fire, circling slowly, with handheld shake from the bass.

constant float EMBER_GROUND = -2.0;

static float emberCore(float3 p, constant Frame& u, NZP) {
    float3 q = p;
    q.xz = rot(u.res.z * 0.12) * q.xz;
    int shape = geneI(u, 1, 3);
    float r = 1.0 + 0.07 * u.hits.x + 0.04 * u.spec.x;
    float d;
    if (shape == 2) {        // ring: a tilted obsidian torus around a hot eye
        float3 t = q;
        t.yz = rot(0.5 + 0.2 * sin(u.res.z * 0.3)) * t.yz;
        d = length(float2(length(t.xz) - 0.95 * r, t.y)) - 0.36 * r;
    } else {
        d = length(q) - r;
    }
    // Volcanic plates: Worley cells raised, the borders between them sunk into cracks.
    float cs = 1.6 + 1.4 * gene(u, 7);
    float4 n = nz4(NZ, q * cs + u.look.y * 10.0);
    d += 0.05 * (1.0 - smoothstep(0.0, 0.18, n.a)) - 0.02 * n.r;
    if (shape == 1) d -= 0.22 * (nfbm(NZ, q * 1.3 + 3.0, 2) - 0.5);
    return d;
}

// Fire: density, temperature, accent ("chemical" flame) fraction and smoke at p.
static float4 emberFire(float3 p, constant Frame& u, float t, NZP) {
    float bass = u.spec.x, energy = u.dyn.x, build = u.dyn.z, lift = u.fx.x + u.fx.z;
    float voice = u.bands.z, snare = u.hits.y;
    float rxz = length(p.xz);
    float py = max(p.y, 0.0);
    // Flame column: wide at the base around the core, narrowing upward; taller with bass, voice, builds.
    float height = 2.0 + 2.0 * bass + 2.2 * voice + 1.5 * build + 2.5 * lift;
    // Tongues: angular lobes that rotate and lick outward on snares.
    float nT = 3.0 + floor(gene(u, 0) * 5.0);
    float ang = atan2(p.z, p.x);
    float tongue = cos(ang * nT + t * 1.3 + p.y * 0.9) * smoothstep(-0.5, 1.5, p.y);
    float shape = 1.25 + 0.5 * energy + 0.8 * lift - rxz * (0.85 + 0.35 * py) - py / height - max(-p.y - 0.5, 0.0) * 1.5;
    shape += tongue * (0.18 + 0.7 * snare);
    // Fire ring (each beat, a ring leaves the core along the ground) and eruption shell on hits.
    float R = 1.1 + u.rhythm.x * 4.0;
    float ring = length(float2(rxz - R, p.y - EMBER_GROUND - 0.3));
    float ringW = exp(-ring * ring * 8.0) * u.rhythm.z;
    float Rb = 1.0 + u.fx.y * 6.0;
    float shellW = exp(-pow(length(p) - Rb, 2.0) * 6.0) * exp(-u.fx.y * 2.0);
    // Smoke: a slow column above the flames.
    float smokeAmt = gene(u, 5);
    float smokeShape = smoothstep(1.5, 3.5, p.y) * (1.6 - rxz * 0.45 + 0.1 * p.y) * smokeAmt;
    // Noise can't lift a point further than this into the flame: skip the fetches in empty space.
    bool flame = shape > -1.3 || ringW > 0.01 || shellW > 0.01;
    if (!flame && smokeShape <= 0.0) return float4(0.0);

    float3 q = p;
    float swirl = 0.3 + 0.6 * gene(u, 6) + 0.4 * build;
    q.xz = rot(q.y * swirl - t * 0.4) * q.xz;
    q.x += sin(p.y * 0.9 + t * 1.7) * 0.35 * voice;   // the voice makes the flames sway
    float dens = 0.0, temp = 0.0, chem = 0.0, smoke = 0.0;
    if (flame) {
        float rise = t * (1.3 + 1.5 * energy + 1.5 * build);
        float3 fq = q * float3(1.05, 0.5, 1.05) - float3(0.0, rise * 0.6, 0.0);
        float n = nwarp(NZ, fq, 0.8, 2);
        // Licks: ridged noise draws thin bright tongues inside the body of the flame.
        float lick = nridge(NZ, fq * float3(1.6, 0.8, 1.6) + 5.0, 1);
        float body = n - 0.56 + shape * 0.33 + 0.12 * lick;
        dens = smoothstep(0.0, 0.22, body) * (0.8 + 0.6 * lick);
        dens += ringW * (0.6 + n) * 1.2 + shellW * n * 1.5;
        // Temperature: white only in the heart, falling through orange to deep red at the edges and top.
        temp = sat(dens * 0.45 + 0.28 * shape - 0.3 * py / height + 0.15 * u.hits.x);
        // Accent flame only in the thin outer layer of the fire (edges, tongue tips), like metal salts in a flame.
        chem = smoothstep(0.02, 0.12, dens) * (1.0 - smoothstep(0.2, 0.5, dens)) * sat((0.6 - temp) * 3.0) * (0.15 + 0.5 * gene(u, 3));
    }
    if (smokeShape > 0.0 && dens < 0.9)
        smoke = sat((nfbm(NZ, q * 0.7 - float3(0.0, t * 0.6, 0.0), 2) - 0.45) * 3.0) * sat(smokeShape) * (1.0 - dens);
    return float4(dens, temp, chem, smoke);
}

static float3 fireColor(constant Frame& u, float temp) {
    // Cosine fire palettes run dark at t = 0.5 and brightest at t = 0; add white heat on top.
    float3 c = pal(u, 0.5 - 0.42 * temp);
    return c * temp * temp + float3(1.0, 0.9, 0.75) * pow(temp, 10.0) * 1.2;
}

// Heat on the ground at distance r from the centre: the fire's own glow plus one ring per recent kick.
static float groundHeat(float r, constant Frame& u, texture2d<float> hist, sampler hs) {
    const float speed = 3.0;
    float age = max(r - 1.2, 0.0) / speed;
    float k = 0.0;
    if (age < 3.5) {
        float a = histScalar(hist, hs, u, 0, age);
        float b = histScalar(hist, hs, u, 0, age + 0.06);
        k = max(a - 0.6 * b, 0.0) * exp(-age * 0.9) * smoothstep(3.5, 2.5, age);
    }
    return 1.4 * exp(-r * 0.45) * (0.5 + u.spec.x) + 2.2 * k;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS, NOISE_ARGS) {
    float2 uv = screenUV(in, u);
    float time = u.res.z, kick = u.hits.x, hat = u.hits.z, air = u.bands.w;

    // Rise camera presets: (distance, height, look-at height, angle offset).
    float pr = u.cam.x;
    float4 P0 = float4(6.0, -0.9, 1.6, 0.0), P1 = float4(4.6, 0.2, 1.0, 1.7), P2 = float4(8.5, -1.5, 2.4, 3.3), P3 = float4(4.4, 4.2, 0.2, 4.8);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    // Musical camera: each bar the camera lurches a step around the fire (direction from a gene),
    // rises and sinks over two bars, dollies in on beats and swings on snares; a slow handheld
    // drift keeps it alive in quiet passages.
    float bars = u.hist.z;
    float dir = gene(u, 6) < 0.5 ? -1.0 : 1.0;
    float drift = time * 0.13;
    float ang = C.w + u.motion.z * 0.8 + dir * (0.5 * bars + 0.25 * sin(drift * 1.7)) + 0.12 * u.hits.y * dir;
    float dist = C.x * (1.0 - 0.07 * u.motion.w - 0.06 * u.rhythm.z) * (1.0 + 0.12 * sin(bars * 1.3 + drift));
    float height = C.y + 0.6 * sin(bars * 1.5708 + drift * 0.7) * (0.4 + 0.6 * u.dyn.y);
    float3 shake = (float3(noise3(float3(time * 9.0, 0, 0)), noise3(float3(0, time * 9.0, 3)), noise3(float3(5, 0, time * 9.0))) - 0.5) * u.cam.y * 0.3;
    float3 hand = (float3(noise3(float3(time * 0.6, 7, 0)), noise3(float3(1, time * 0.6, 9)), noise3(float3(4, 2, time * 0.6))) - 0.5) * 0.5;
    float3 ro = float3(cos(ang) * dist, height, sin(ang) * dist) + shake + hand;
    float3 ta = float3(0.4 * sin(drift * 2.3 + bars * 0.7), C.z + 0.35 * sin(drift * 1.9), 0.4 * cos(drift * 2.1));
    float3x3 cam = lookAt(ro, ta, u.cam.z * 0.35 + 0.1 * sin(bars * 0.9 + drift));
    // Heat shimmer: the view wobbles slightly above the fire, more with bass.
    float2 sh = (nz4(NZ, float3(uv * 6.0, time * 1.5)).rg - 0.5) * (0.004 + 0.01 * u.spec.x) * smoothstep(-0.3, 0.3, uv.y);
    float3 rd = normalize(cam * float3(uv + sh, 1.35 - 0.3 * u.cam.w));

    // Background: smouldering sky, accent-tinted haze drifting through it.
    float hz = nfbm(NZ, rd * 2.5 + float3(time * 0.05, -time * 0.08, 0.0), 2);
    float3 col = pal(u, 0.45) * 0.02 * (1.0 + 2.0 * sat(-rd.y));
    col += acc(u, 0.3 + hz * 0.4 + u.look.z) * pow(sat(hz - 0.35) * 2.0, 2.0) * 0.06 * (0.6 + u.dyn.x);

    // Core: analytic bound, then SDF steps.
    float tCore = 1e3;
    float b = dot(ro, rd), c = dot(ro, ro) - 1.55 * 1.55, disc = b * b - c;
    if (disc > 0.0) {
        float t0 = max(-b - sqrt(disc), 0.0);
        float tt = t0;
        for (int i = 0; i < 22; ++i) {
            float d = emberCore(ro + rd * tt, u, NZ);
            if (d < 0.002) { tCore = tt; break; }
            tt += d * 0.85;
            if (tt > t0 + 3.2) break;
        }
    }
    // Ground plane.
    float tGround = rd.y < 0.0 ? (EMBER_GROUND - ro.y) / rd.y : 1e3;
    if (tGround < 0.0) tGround = 1e3;
    float tSolid = min(tCore, tGround);

    if (tGround < tCore && tGround < 1e3) {
        float3 p = ro + rd * tGround;
        float r = length(p.xz);
        float gs = 0.45 + 0.5 * gene(u, 2);
        float4 n = nz4(NZ, float3(p.xz * gs, 0.5));
        float4 n2 = nz4(NZ, float3(p.xz * gs * 3.1, 2.5));
        float crack = 1.0 - smoothstep(0.0, 0.05 + 0.03 * u.spec.x, n.a);
        float fine = 1.0 - smoothstep(0.0, 0.06, n2.a);
        float heat = groundHeat(r, u, hist, hs);
        // Lava in the cracks flows slowly; plates are dark basalt lit by the fire above.
        float flow = nfbm(NZ, float3(p.xz * 1.5, time * 0.3), 2);
        float3 lava = fireColor(u, sat(0.45 + 0.35 * heat + 0.2 * flow)) * (crack + 0.35 * fine * crack) * (0.3 + heat);
        float3 rock = mix(float3(0.035, 0.03, 0.03), acc(u, 0.6 + n.r * 0.3) * 0.05, 0.4) * (0.4 + 0.6 * n2.r);
        rock *= fireColor(u, 0.7) * 6.0 / (1.0 + r * r * 0.12) + 0.15;
        float3 g = rock + lava * 1.5;
        g += fireColor(u, 0.6) * (1.0 - crack) * exp(-n.b * 4.0) * heat * 0.05;   // plates glow at their hot centres
        col = mix(col, g, exp(-max(tGround - 4.0, 0.0) * 0.04));
    }

    // Volume: march a vertical cylinder around the fire (wider while an eruption shell expands),
    // front to back, from a dithered start (trails average it).
    float Rv = 3.4 + 3.0 * exp(-u.fx.y * 2.0);
    float a2 = dot(rd.xz, rd.xz), b2 = dot(ro.xz, rd.xz), c2 = dot(ro.xz, ro.xz) - Rv * Rv, dv = b2 * b2 - a2 * c2;
    float3 accum = float3(0.0);
    float T = 1.0;
    if (dv > 0.0 && a2 > 1e-6) {
        float tA = max(0.0, (-b2 - sqrt(dv)) / a2), tB = min((-b2 + sqrt(dv)) / a2, tSolid);
        // Clip to the slab y in [ground, 8].
        float ry = abs(rd.y) < 1e-5 ? 1e-5 : rd.y;
        float ty0 = (EMBER_GROUND - ro.y) / ry, ty1 = (8.0 - ro.y) / ry;
        tA = max(tA, min(ty0, ty1)); tB = min(tB, max(ty0, ty1));
        const int N = 32;
        float stepL = max(tB - tA, 0.0) / float(N);
        float tt = tA + stepL * frameDither(in, u);
        float sparkOn = 0.88 - 0.12 * gene(u, 4) - 0.25 * hat - 0.25 * air - 0.2 * u.fx.x;
        for (int i = 0; i < N; ++i) {
            if (tt > tB || T < 0.02) break;
            float3 p = ro + rd * tt;
            float4 f = emberFire(p, u, time, NZ);
            if (f.x > 0.01) {
                float a = 1.0 - exp(-f.x * stepL * 1.8);
                float3 fc = fireColor(u, f.y);
                float3 cc = acc(u, 0.15 + f.y * 0.5 + u.look.z) * (0.4 + 1.6 * f.y);
                accum += T * a * mix(fc, cc, f.z) * (0.9 + 0.5 * u.dyn.y);
                T *= 1.0 - a * 0.85;
            }
            if (f.w > 0.01) {
                // Smoke: absorbs, lit from below by the fire.
                float a = 1.0 - exp(-f.w * stepL * 1.5);
                accum += T * a * (fireColor(u, 0.55) * 0.35 + acc(u, 0.7) * 0.02) / (1.0 + max(p.y - 1.5, 0.0));
                T *= 1.0 - a * 0.7;
            }
            // Sparks: hashed points in rising, swirling cells, stretched along their motion (every other step).
            if ((i & 1) == 0) {
                float3 sp = p * 2.2;
                sp.xz = rot(time * 0.3 + p.y * 0.2) * sp.xz;
                sp.y -= time * (2.2 + 2.0 * u.dyn.z);
                float3 cell = floor(sp);
                float3 jp = hash33(cell);
                float3 dd = (fract(sp) - jp) * float3(1.0, 0.28, 1.0);
                float sd = dot(dd, dd);
                float on = step(sparkOn, jp.x) * sat(f.x * 3.0 + 0.15 + 0.3 * air);
                float3 sc = mix(fireColor(u, 0.95), acc(u, jp.y) * 2.0, step(0.6, jp.z) * (0.3 + 0.7 * gene(u, 3)));
                accum += T * on * exp(-sd * 1400.0) * sc * (2.0 + 8.0 * hat + 6.0 * air) * stepL * 2.0;
            }
            tt += stepL;
        }
    }

    if (tCore < tGround && tCore < 1e3) {
        float3 p = ro + rd * tCore;
        const float2 k = float2(1.0, -1.0) * 0.004;
        float3 n = normalize(k.xyy * emberCore(p + k.xyy, u, NZ) + k.yyx * emberCore(p + k.yyx, u, NZ) +
                             k.yxy * emberCore(p + k.yxy, u, NZ) + k.xxx * emberCore(p + k.xxx, u, NZ));
        float3 q = p;
        q.xz = rot(time * 0.12) * q.xz;
        float cs = 1.6 + 1.4 * gene(u, 7);
        float4 nzc = nz4(NZ, q * cs + u.look.y * 10.0);
        // Lava cracks: Worley borders, wider and hotter with bass, kicks and lifts; lava flows inside.
        float width = 0.035 + 0.05 * u.spec.x + 0.12 * u.fx.z + 0.05 * kick;
        float crack = 1.0 - smoothstep(0.0, width, nzc.a);
        float glowNear = exp(-nzc.a * 10.0);   // subsurface glow bleeding from the cracks
        float flow = nfbm(NZ, q * 3.0 + float3(0.0, -time * 0.7, 0.0), 3);
        float cosv = sat(dot(n, -rd));
        float fres = pow(1.0 - cosv, 4.0);
        // Obsidian: glossy black reflecting the fire, with a thin-film sheen in the accent colour.
        float3 rr = reflect(rd, n);
        float3 env = fireColor(u, 0.55 + 0.3 * sat(rr.y)) * (0.4 + 1.2 * sat(rr.y + 0.3)) + fireColor(u, 0.7) * sat(-rr.y) * 0.5;
        float3 surf = env * (0.04 + 0.7 * fres) * (0.6 + 0.4 * nzc.r);
        surf += acc(u, fres * 0.8 + nzc.g * 0.5 + u.look.z) * fres * (0.25 + 0.5 * u.bands.z);
        surf += fireColor(u, 0.55 + 0.25 * flow) * glowNear * 0.25 * (0.6 + u.spec.x);
        surf += fireColor(u, 0.75 + 0.2 * flow + 0.15 * kick) * crack * (1.2 + 2.5 * u.spec.x + 3.0 * u.fx.z + 2.0 * kick);
        col = surf;
    }
    col = col * T + accum;
    // Heat glow around the core.
    float dc = length(cross(rd, -ro));
    col += fireColor(u, 0.6) * exp(-dc * 1.2) * 0.12 * (1.0 + u.spec.x + kick);
    return float4(col, 1.0);
}
