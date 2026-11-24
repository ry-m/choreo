// Scene "Laser Nebula": flying low over a wet black floor with a neon grid toward a portal that fires
// fans of lasers through nebula haze. Everything is analytic (no SDF march), which keeps this cheap.
//   kick   -> the portal pulses, a row of light runs toward the camera along the grid, haze puffs
//   snare  -> beams flick across; a second, accent-coloured fan fires
//   hats   -> beams strobe at high intensity; air -> stars and grid sparkles
//   voice  -> (sustained mids) aurora curtains rise over the horizon; beams thicken and glow
//   bass   -> the floor and portal glow; builds -> beams sweep faster
// Beams are drawn through smoke (noise along each beam) and never thinner than a pixel, so they
// don't shimmer in the distance. The floor is glossy with wet patches that mirror the beams sharply.
// Remix genes: 0 beam count, 1 beam spread, 2 primary/accent beam split, 3 floor pattern
// (square / diagonal / radial), 4 portal shape (ring / double / polygon), 5 nebula density,
// 6 sweep speed, 7 smoke amount.
// Camera: forward flight with roll; a sideways step and roll each bar; section changes move it.

// Distance between the ray (ro, rd) and the beam line (o, d), the ray parameter and the beam parameter.
static float3 rayLine(float3 ro, float3 rd, float3 o, float3 d) {
    float3 w = ro - o;
    float b = dot(rd, d), dd = dot(rd, w), e = dot(d, w);
    float den = max(1.0 - b * b, 1e-4);
    float tr = (b * e - dd) / den;
    float tl = (e - b * dd) / den;
    if (tl <= 0.0) return float3(1e3, -1.0, 0.0);  // closest point is behind the emitter
    return float3(length((ro + rd * tr) - (o + d * tl)), tr, tl);
}

static float3 lasers(float3 ro, float3 rd, float tMax, float px, bool smoke, constant Frame& u, float3 stage, NZP) {
    int variant = int(floor(u.look.x + 0.5)) % 4;
    float bar = u.rhythm.y, beat = u.rhythm.z, snare = u.hits.y, strobe = u.fx.w, voice = u.bands.z;
    float spread = 0.6 + 0.9 * gene(u, 1);
    float sweepT = TAU * bar * (0.5 + gene(u, 6)) + u.dyn.z * u.res.z * 0.8;
    float3 col = float3(0.0);
    const int NMAX = 20;
    int N = 10 + int(gene(u, 0) * 10.0);
    for (int i = 0; i < NMAX; ++i) {
        if (i >= N) break;
        float fi = float(i) / float(N - 1) - 0.5;
        float h = hash11(float(i) * 7.7 + u.look.y * 13.0);
        float sweep = sin(sweepT + fi * 3.0) * 0.6 + snare * (h - 0.5) * 1.2;
        bool accentBeam = h < 0.25 + 0.5 * gene(u, 2);
        float3 o = stage, d;
        if (variant == 0) {        // fan from the portal toward the camera
            d = normalize(float3(fi * 2.2 * spread + sweep * 0.5, 0.25 * sin(u.res.z * 0.7 + fi * 4.0) + 0.05, -1.0));
        } else if (variant == 1) { // cross: two fans scissoring
            float s = i % 2 == 0 ? 1.0 : -1.0;
            d = normalize(float3(s * (fi + 0.5) * 1.6 * spread * cos(sweepT), 0.3 + 0.4 * (fi + 0.5) * s * sin(sweepT), -1.0));
        } else if (variant == 2) { // cage: beams from a ring around the portal, converging behind the camera
            float a = fi * TAU + u.motion.y;
            o = stage + float3(cos(a), sin(a) + 1.0, 0.0) * 3.0 * spread;
            d = normalize(float3(-cos(a) * 0.15, -sin(a) * 0.15, -1.0));
        } else {                   // curtain: vertical sheet from above, sweeping sideways
            o = float3(stage.x + fi * 14.0 * spread + sweep * 3.0, 9.0, stage.z - 12.0);
            d = normalize(float3(sin(fi * 5.0 + u.res.z) * 0.3, -1.0, 0.25));
        }
        // On a snare, accent beams fire as a second fan, mirrored.
        if (accentBeam) d.x = mix(d.x, -d.x, sat(snare * 1.5));
        float3 dl = rayLine(ro, rd, o, d);
        if (dl.y <= 0.0 || dl.y > tMax) continue;
        float dist = dl.x;
        // Never thinner than a pixel at that distance (energy kept), so distant beams don't shimmer.
        float w0 = 0.012 + 0.006 * beat + 0.01 * voice;
        float w = max(w0, px * dl.y * 0.8);
        float core = exp(-dist * dist / (w * w)) * (w0 / w);
        float halo = 0.03 / (0.03 + dist * dist * 6.0);
        // Smoke: the beam is seen where it crosses drifting haze.
        float sm = 1.0;
        if (smoke && halo > 0.05) {
            float3 bp = o + d * dl.z;
            sm = 0.35 + 1.3 * nfbm(NZ, bp * 0.35 + float3(0.0, u.res.z * 0.25, u.res.z * 0.1), 2) * (0.4 + gene(u, 7));
        }
        float on = 0.55 + 0.45 * sin(u.res.z * (2.0 + 3.0 * h) + h * 10.0);
        on = mix(on, step(0.5, fract(u.res.z * 12.0 + h)), strobe);  // hat strobe at high intensity
        float3 c = accentBeam ? acc(u, h * 0.3 + u.look.z) : pal(u, h * 0.35 + float(i % 3) * 0.33 + u.look.z);
        col += c * (core * 6.0 + halo * 0.6 * sm) * on * (0.5 + 1.2 * u.dyn.y + 1.5 * beat + 0.8 * voice) * exp(-dl.y * 0.025);
    }
    return col;
}

static float3 nebula(float3 rd, constant Frame& u, float travel, NZP) {
    float dens = 0.6 + 0.8 * gene(u, 5);
    float3 q = rd * 2.2 + float3(0.0, 0.0, travel * 0.01) + u.look.y * 10.0;
    float n = nwarp(NZ, q, 0.7, 4);
    float n2 = nfbm(NZ, q * 1.7 + 4.0, 3);
    float3 col = pal(u, n * 0.8 + u.look.z + 0.2) * pow(sat(n - 0.42) * 2.0, 2.0) * 0.6 * dens;
    col += acc(u, n2 + 0.55 + u.look.z) * pow(sat(n2 - 0.5) * 2.2, 3.0) * 0.5 * dens;
    // Dark dust lanes cut through it.
    col *= 0.4 + 0.6 * smoothstep(0.3, 0.55, nfbm(NZ, q * 3.1 + 9.0, 2));
    // Aurora curtains over the horizon, rising with the voice.
    float az = atan2(rd.x, rd.z);
    float cur = nz4(NZ, float3(az * 6.0, u.res.z * 0.15, 1.0)).r;
    float top = 0.05 + 0.35 * u.bands.z * (0.5 + cur);
    float aur = smoothstep(top, top * 0.3, rd.y) * smoothstep(-0.02, 0.03, rd.y) * (0.6 + 0.4 * sin(az * 80.0 + cur * 6.0));
    col += mix(acc(u, 0.2 + cur * 0.3 + u.look.z), pal(u, 0.6 + u.look.z), cur) * aur * u.bands.z * 0.5;
    float3 sc = floor(rd * 300.0);
    col += step(0.9975, hash31(sc)) * (0.5 + 2.0 * u.hits.z + 2.0 * u.bands.w) * float3(0.9, 0.95, 1.0);
    return col * (0.6 + 0.6 * u.dyn.x);
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS, NOISE_ARGS) {
    float2 uv = screenUV(in, u);
    float kick = u.hits.x, beat = u.rhythm.z, time = u.res.z;
    float travel = u.motion.x * 3.0;

    // Flight camera presets: (x, height, pitch, yaw); plus a sideways step and roll every bar.
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 0.6, 0.05, 0.0), P1 = float4(0.0, 3.5, -0.3, 0.0), P2 = float4(0.0, 1.6, 0.0, 0.0), P3 = float4(3.0, 1.0, 0.0, -0.25);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float bars = u.hist.z;
    float side = 1.6 * sin(bars * 1.5708);                  // left / centre / right / centre, a bar each
    float3 ro = float3(C.x + side + 0.4 * sin(time * 0.21), max(C.y + 0.15 * sin(time * 0.37) - 0.1 * u.motion.w + 0.3 * sin(bars * 0.7), 0.25), travel);
    float3 fwd = normalize(float3(sin(C.w - 0.04 * side), C.z, cos(C.w)));
    float3x3 cam = lookAt(ro, ro + fwd, u.cam.z * 0.6 + 0.05 * sin(u.motion.y) - 0.06 * side);
    float fov = 1.25 - 0.3 * u.cam.w;
    float3 rd = normalize(cam * float3(uv, fov));
    float px = 1.0 / (u.res.y * fov);
    float3 stage = float3(0.0, 2.2, travel + 38.0);

    float3 col = nebula(rd, u, travel, NZ);

    // Portal far ahead (ring, double ring or polygon), pulsing on kicks and bass, expanding on hits.
    {
        float tp = (stage.z - ro.z) / max(rd.z, 1e-3);
        if (rd.z > 0.0) {
            float3 p = ro + rd * tp - stage;
            float R = 5.0 + 1.2 * kick + u.fx.y * 18.0 * exp(-u.fx.y);
            int shape = geneI(u, 4, 3);
            float r = length(p.xy);
            if (shape == 2) {   // polygon (5-7 sides), slowly turning
                float ns = 5.0 + floor(gene(u, 0) * 3.0);
                float a = atan2(p.y, p.x) + time * 0.2;
                r *= cos(modf1(a, TAU / ns) - 3.14159 / ns) / cos(3.14159 / ns);   // R on the polygon of circumradius R
            }
            float d = abs(r - R);
            if (shape == 1) d = min(d, abs(r - R * 0.72) * 1.3);
            col += pal(u, 0.1 + u.look.z) * (0.05 / (0.05 + d * d * 2.0)) * (1.0 + 4.0 * kick + 1.0 * u.fx.x + 1.5 * u.spec.x);
            col += acc(u, 0.6 + u.look.z) * exp(-r * 0.3) * 0.25 * (1.0 + beat + u.spec.x);
        }
    }

    // Floor: glossy black at y = 0 with a neon grid; rows of light run toward the camera each beat.
    float tMax = 200.0;
    if (rd.y < 0.0) {
        float tf = -ro.y / rd.y;
        tMax = tf;
        float3 p = ro + rd * tf;
        int pattern = geneI(u, 3, 3);
        float2 g = p.xz * 0.25;
        if (pattern == 1) g = float2(g.x + g.y, g.x - g.y) * 0.7071;                       // diagonal
        if (pattern == 2) g = float2(length(p.xz - stage.xz) * 0.25, atan2(p.x - stage.x, p.z - stage.z) * 3.0);  // radial
        float2 fw = fwidth(g) + 1e-4;
        float2 dl = 0.5 - abs(fract(g) - 0.5);                 // distance to the nearest grid line
        float2 gl = 1.0 - smoothstep(float2(0.0), fw * 1.5, dl);
        gl *= sat(0.3 / max(fw.x + fw.y, 1e-3));               // fade where lines get sub-pixel (no moire)
        float grid = max(gl.x, gl.y) * exp(-tf * 0.03);
        float row = fract((p.z - travel) * 0.05 + u.rhythm.x);
        float wave = exp(-pow((row - 0.5) * 9.0, 2.0)) * (0.3 + 1.5 * beat);
        float3 gc = mix(pal(u, 0.55 + p.x * 0.01 + u.look.z), acc(u, 0.3 + u.look.z), 0.5 + 0.5 * sin(p.z * 0.05 + time * 0.3));
        // Sparkles riding the grid lines on air / hats.
        float spk = step(0.985 - 0.03 * u.bands.w, hash21(floor(p.xz * 3.0) + floor(time * 15.0))) * grid;
        float3 floorCol = gc * grid * (0.12 + 1.6 * wave + 0.6 * u.spec.x) + gc * spk * (1.0 + 3.0 * u.bands.w);
        // Wet patches mirror sharply; the rest is satin (dimmer, softer reflection). Fine grain texture.
        float4 fz = nz4(NZ, float3(p.xz * 0.12, 0.3));
        float wet = smoothstep(0.45, 0.6, fz.r);
        float grain = 0.85 + 0.3 * nz4(NZ, float3(p.xz * 3.0, 1.7)).g;
        float3 rr = reflect(rd, float3(0.0, 1.0, 0.0));
        rr.xz += (fz.gb - 0.5) * 0.04 * (1.0 - wet);           // satin: slightly wavy reflection
        rr = normalize(rr);
        float fres = 0.1 + 0.9 * pow(1.0 - sat(-rd.y), 5.0);
        float3 refl = lasers(p + float3(0.0, 0.01, 0.0), rr, 200.0, px * 2.0, false, u, stage, NZ) * 0.5 + nebula(rr, u, travel, NZ) * 0.2;
        col = floorCol * grain * (1.0 - 0.5 * wet) + refl * fres * mix(0.35, 1.0, wet);
    }
    col += lasers(ro, rd, tMax, px, true, u, stage, NZ);

    // Haze: fog toward the horizon tinted by both palettes, puffing on kicks.
    float haze = exp(-abs(rd.y) * 7.0);
    col += mix(pal(u, 0.75 + u.look.z), acc(u, 0.4 + u.look.z), 0.4) * haze * (0.1 + 0.3 * kick + 0.3 * u.dyn.z);
    return float4(col, 1.0);
}
