// Scene "Ember Bloom": an obsidian heart with glowing lava cracks inside a column of volumetric fire.
// Bass feeds the flames, each beat sends a ring of fire outward, hats throw sparks, lifts erupt.
// Camera: low and close, looking up into the fire, circling slowly, with handheld shake from the bass.

static float emberCore(float3 p, constant Frame& u) {
    float r = 1.0 + 0.06 * u.hits.x;
    return length(p) - r - 0.08 * (noise3(p * 3.0 + u.look.y * 10.0) - 0.5);
}

// Fire density at p (0..~1.5) and its temperature, from rising, swirling noise around the core.
static float2 emberFire(float3 p, constant Frame& u, float t) {
    float bass = u.spec.x, energy = u.dyn.x, build = u.dyn.z, lift = u.fx.x + u.fx.z;
    float rxz = length(p.xz);
    // Flame column: wide at the base around the core, narrowing upward; taller with bass and builds.
    float height = 2.2 + 2.5 * bass + 1.5 * build + 2.5 * lift;
    float shape = 1.25 + 0.5 * energy + 0.8 * lift - rxz * (0.75 + 0.35 * max(p.y, 0.0)) - max(p.y, 0.0) / height - max(-p.y - 0.5, 0.0) * 1.5;
    // Fire ring (each beat, a ring leaves the core along the ground) and eruption shell on hits.
    float R = 1.1 + u.rhythm.x * 4.0;
    float ring = length(float2(rxz - R, p.y + 0.6));
    float ringW = exp(-ring * ring * 10.0) * u.rhythm.z;
    float Rb = 1.0 + u.fx.y * 6.0;
    float shellW = exp(-pow(length(p) - Rb, 2.0) * 6.0) * exp(-u.fx.y * 2.0);
    // Empty space: noise is at most 1, so skip it where nothing could be visible.
    if (shape * 0.4 + 0.45 <= 0.0 && ringW < 0.01 && shellW < 0.01) return float2(0.0);
    int variant = int(floor(u.look.x + 0.5));
    float swirl = 0.4 + 0.35 * float(variant % 3);
    float3 q = p;
    q.xz = rot(q.y * swirl - t * 0.4) * q.xz;
    float rise = t * (1.2 + 1.5 * energy + 1.5 * build);
    float n = fbm3(q * float3(1.4, 0.9, 1.4) - float3(0.0, rise, 0.0), 3) * 1.07;
    float dens = sat((n - 0.5 + shape * 0.4) * 2.2);
    dens += ringW * (0.6 + n) * 1.2 + shellW * n * 1.5;
    float temp = sat(dens * 0.75 + 0.25 * shape - 0.25 * max(p.y, 0.0) / height);
    return float2(dens, temp);
}

static float3 fireColor(constant Frame& u, float temp) {
    // Cosine fire palettes run dark at t = 0.5 and brightest at t = 0; add white heat on top.
    float3 c = pal(u, 0.5 - 0.42 * temp);
    return c * temp * temp * 1.0 + float3(1.0, 0.9, 0.75) * pow(temp, 10.0) * 1.2;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]]) {
    float2 uv = screenUV(in, u);
    float time = u.res.z, kick = u.hits.x, hat = u.hits.z;

    // Rise camera presets: (distance, height, look-at height, angle offset).
    float pr = u.cam.x;
    float4 P0 = float4(6.0, -0.9, 1.6, 0.0), P1 = float4(4.6, 0.2, 1.0, 1.7), P2 = float4(8.5, -1.6, 2.4, 3.3), P3 = float4(4.2, 4.2, 0.4, 4.8);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float ang = C.w + u.motion.z * 0.8;
    float dist = C.x * (1.0 - 0.07 * u.motion.w);
    float3 shake = (float3(noise3(float3(time * 9.0, 0, 0)), noise3(float3(0, time * 9.0, 3)), noise3(float3(5, 0, time * 9.0))) - 0.5) * u.cam.y * 0.25;
    float3 ro = float3(cos(ang) * dist, C.y, sin(ang) * dist) + shake;
    float3 ta = float3(0.0, C.z, 0.0);
    float3x3 cam = lookAt(ro, ta, u.cam.z * 0.2);
    float3 rd = normalize(cam * float3(uv, 1.35 - 0.3 * u.cam.w));

    // Background: smouldering dark, warmer toward the ground.
    float3 col = pal(u, 0.45) * 0.02 * (1.0 + 2.0 * sat(-rd.y));

    // Core: analytic sphere bound, refined by a few SDF steps.
    float tCore = 1e3;
    float b = dot(ro, rd), c = dot(ro, ro) - 1.3 * 1.3, disc = b * b - c;
    if (disc > 0.0) {
        float t0 = -b - sqrt(disc);
        if (t0 > 0.0) {
            float tt = t0;
            for (int i = 0; i < 16; ++i) {
                float d = emberCore(ro + rd * tt, u);
                if (d < 0.002) { tCore = tt; break; }
                tt += d;
                if (tt > t0 + 2.6) break;
            }
        }
    }

    // Volume: march the fire's bounding sphere front to back.
    float Rv = 6.5;
    float bv = dot(ro, rd), cv = dot(ro, ro) - Rv * Rv, dv = bv * bv - cv;
    float3 acc = float3(0.0);
    float T = 1.0;
    if (dv > 0.0) {
        float tA = max(0.0, -bv - sqrt(dv)), tB = min(-bv + sqrt(dv), tCore);
        const int N = 30;
        float stepL = (tB - tA) / float(N);
        float tt = tA + stepL * frameDither(in, u);
        for (int i = 0; i < N; ++i) {
            if (tt > tB || T < 0.02) break;
            float3 p = ro + rd * tt;
            float2 f = emberFire(p, u, time);
            if (f.x > 0.01) {
                float a = 1.0 - exp(-f.x * stepL * 2.2);
                acc += T * a * fireColor(u, f.y) * (1.2 + 0.8 * u.dyn.y);
                T *= 1.0 - a * 0.85;
            }
            // Sparks: hashed points in rising cells (every other step).
            if ((i & 1) == 0) {
            float3 sp = p * 2.5 + float3(0.0, time * 2.2, 0.0);
            float3 cell = floor(sp);
            float3 jp = hash33(cell);
            float sd = length(fract(sp) - jp);
            float on = step(0.9 - 0.2 * hat - 0.2 * u.fx.x, jp.x) * sat(f.x * 4.0 + 0.1);
            acc += T * on * exp(-sd * sd * 900.0) * fireColor(u, 0.95) * (1.5 + 6.0 * hat) * stepL * 2.0;
            }
            tt += stepL;
        }
    }

    if (tCore < 1e3) {
        float3 p = ro + rd * tCore;
        const float2 k = float2(1.0, -1.0) * 0.003;
        float3 n = normalize(k.xyy * emberCore(p + k.xyy, u) + k.yyx * emberCore(p + k.yyx, u) +
                             k.yxy * emberCore(p + k.yxy, u) + k.xxx * emberCore(p + k.xxx, u));
        // Glossy obsidian lit by the fire around it, with lava cracks (ridged noise) that glow
        // brighter and wider with bass, kicks and lifts.
        float3 q = p * 2.2;
        q.xz = rot(time * 0.1) * q.xz;
        // Long lava veins: ridges of low-frequency noise, wobbled by a finer octave.
        float cr = abs(noise3(q * 0.8 + u.look.y * 5.0 + 0.25 * noise3(q * 3.0)) - 0.5);
        float width = 0.02 + 0.03 * u.spec.x + 0.08 * u.fx.z + 0.02 * kick;
        float crack = smoothstep(width, 0.0, cr);
        float fres = pow(1.0 - sat(dot(n, -rd)), 4.0);
        float3 surf = fireColor(u, 0.7) * (0.05 + 0.6 * fres) * (0.5 + n.y * 0.5 + 0.5);
        surf += fireColor(u, 0.8 + 0.15 * kick) * crack * (1.0 + 2.0 * u.spec.x + 3.0 * u.fx.z);
        col = surf;
    }
    col = col * T + acc;
    // Heat glow around the core.
    float dc = length(cross(rd, -ro));
    col += fireColor(u, 0.6) * exp(-dc * 1.2) * 0.15 * (1.0 + u.spec.x);
    return float4(col, 1.0);
}
