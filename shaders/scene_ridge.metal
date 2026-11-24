// Scene "Spectral Ridge": the 3D spectrogram waterfall as an organic landscape. The last ~4.3 s of the
// spectrum shapes rolling land (z = time, now at the front; x = frequency, bass in the middle mirrored
// outward, or low-to-high in one variant), softly lit by a low sun or moon and fading into the same
// sky. The music shows as light inside the land (veins, cracks, glowing crests) rather than lines.
//   kick   -> the newest ridge glows, and each kick leaves a wave of light that rolls back in time
//   snare  -> waves in the accent colour (the land shows the drum pattern of the last bars)
//   voice  -> aurora curtains in the sky, a glowing mist in the valleys
//   hats / air -> drifting spores flicker, glints and stars twinkle
//   sub    -> the sun swells, the lake ripples; builds raise the land
// Remix genes: 0 vein / crack density, 1 accent split frequency, 2 material (bioluminescent moss /
// dunes / ice / lava crust), 3 mirror lake, 4 height and curvature, 5 colour mapping (frequency /
// height / age), 6 camera direction, 7 sky (low sun / moonlit night / eclipse).
// Camera: low flight over the front edge looking back in time; presets give overview / side / close;
// every bar steps the camera sideways and up.

constant float RIDGE_LEN = 26.0;   // z extent of the history
constant float RIDGE_W = 7.5;      // half width (x) of the spectrum
constant float RIDGE_WATER = 0.05; // lake level
constant float3 RIDGE_SUN = float3(0.0, 0.1191, 0.9929);   // direction of the sky object (low, ahead)

static float ridgeFreq(constant Frame& u, float x, thread float& edge) {
    int variant = int(floor(u.look.x + 0.5)) % 4;
    float f = variant == 1 ? (x / RIDGE_W + 1.0) * 0.5   // classic: low left, high right
                           : abs(x) / RIDGE_W;           // mirrored: bass in the middle
    edge = variant == 1 ? smoothstep(1.0, 0.95, abs(x) / RIDGE_W) : smoothstep(1.0, 0.9, f);
    return sat(f);
}
// z units per second the history moves back: texture locked to the data rides with it.
static float ridgeScroll(constant Frame& u) { return u.res.z * RIDGE_LEN * u.hist.y / (HIST_ROWS - 4.0); }
static float ridgeAge(constant Frame& u, float z) { return max(z, 0.0) / RIDGE_LEN * (HIST_ROWS - 4.0) / u.hist.y; }

static float ridgeH(texture2d<float> hist, sampler hs, constant Frame& u, NZP, float2 xz) {
    float edge;
    float f = ridgeFreq(u, xz.x, edge);
    float age = ridgeAge(u, xz.y);
    // Two taps offset in frequency and time: rounds off the band corners and frame-to-frame jitter.
    const float db = 0.5 / 31.0;
    float v = 0.5 * (histSpec(hist, hs, u, pow(max(f - db, 0.0), 0.85), age).r +
                     histSpec(hist, hs, u, pow(f + db, 0.85), age + 0.05).r);
    float n = nz4(NZ, float3(xz.x * 0.6, (xz.y - ridgeScroll(u)) * 0.6, 2.5)).r;   // rolling ground
    float scale = 1.6 + 1.3 * gene(u, 4) + 1.0 * u.dyn.y + 0.8 * u.dyn.z;
    float h = v * sqrt(v) * scale * edge * (0.8 + 0.4 * n) + (n - 0.5) * 0.4;
    h -= gene(u, 4) * 0.012 * xz.x * xz.x;   // curvature: the far sides fall away
    h *= smoothstep(-0.6, 0.2, xz.y) * smoothstep(RIDGE_LEN, RIDGE_LEN - 4.0, xz.y);
    // With the lake, the quiet ground sits well under the water (a margin larger than the march's
    // hit tolerance far away, or distant rays flicker between land and water in rings).
    // Ahead of "now" the ground falls away (open sky beyond the live edge from the side).
    h -= 5.0 * smoothstep(-2.5, -12.0, xz.y);
    return gene(u, 3) > 0.45 ? h - 0.25 : h;
}

// Heightfield march: conservative steps (slopes can be steep), then bisection. Returns t or -1.
static float ridgeMarch(float3 ro, float3 rd, int steps, float tMax, float floorY, constant Frame& u,
                        texture2d<float> hist, sampler hs, NZP) {
    const float hMax = 5.0;
    float t = 0.05, tPrev = 0.05;
    bool hit = false;
    int i = 0;
    for (; i < steps && t < tMax; ++i) {
        float3 p = ro + rd * t;
        if (p.y > hMax && rd.y >= 0.0) break;
        if (p.y < floorY) return -1.0;   // under the lake: the water is drawn instead
        float dy = p.y - ridgeH(hist, hs, u, NZ, p.xz);
        if (dy < 0.002 * t) { hit = true; break; }
        tPrev = t;
        t += max(dy * 0.45, 0.01 + t * 0.006);
    }
    // Out of steps while skimming low over the land: take where we got to (it is far and fogged)
    // rather than showing sky through the ground.
    if (!hit && i == steps && rd.y < 0.0) return t;
    if (!hit) return -1.0;
    for (int i = 0; i < 5; ++i) {
        float tm = 0.5 * (t + tPrev);
        float3 p = ro + rd * tm;
        if (p.y > ridgeH(hist, hs, u, NZ, p.xz)) tPrev = tm; else t = tm;
    }
    return t;
}

static float3 ridgeSunCol(constant Frame& u) {
    float3 c = mix(pal(u, 0.12 + u.look.z), float3(1.0, 0.9, 0.8), 0.3);
    return c * (geneI(u, 7, 3) == 1 ? 0.35 : 1.0) * (0.85 + 0.4 * u.bands.x);
}

// Sky gradient and sun scatter: also the colour of the air (fog) over the land, so they match.
static float3 ridgeAtmos(float3 rd, constant Frame& u) {
    float hue = u.look.z;
    bool night = geneI(u, 7, 3) == 1;
    float y = rd.y;
    float3 zen = mix(pal(u, 0.6 + hue), acc(u, 0.75 + hue), 0.5);
    zen *= zen * (night ? 0.02 : 0.06);
    float3 hor = mix(pal(u, 0.1 + hue), acc(u, 0.9 + hue), 0.25);
    hor *= hor * (night ? 0.06 : 0.2);   // squared: richer, less milky
    float3 col = mix(hor, zen, sat(pow(max(y, 0.0) * 2.5, 0.6)));
    col *= y < 0.0 ? 0.7 : 1.0;
    float s = max(dot(rd, RIDGE_SUN), 0.0);
    col += ridgeSunCol(u) * (pow(s, 6.0) * 0.18 + pow(s, 48.0) * 0.35);
    return col;
}

static float3 ridgeSky(float3 rd, float px, constant Frame& u, NZP) {
    float hue = u.look.z, sub = u.bands.x, voice = u.bands.z, air = u.bands.w, kick = u.hits.x;
    float T = u.res.z;
    float y = rd.y;
    int obj = geneI(u, 7, 3);
    float3 col = ridgeAtmos(rd, u);
    float3 sunC = ridgeSunCol(u);

    // Sky object.
    float2 c = float2(rd.x, y - RIDGE_SUN.y);
    float r = length(c);
    float R = 0.07 + 0.012 * sub;
    if (obj == 0) {           // low sun
        col += sunC * 2.2 * smoothstep(R + px, R - px, r) * (1.0 + 0.5 * kick);
    } else if (obj == 1) {    // moon: cratered, lit from the side
        R *= 1.6;
        float2 q = c / R;
        float disc = smoothstep(R + px, R - px, r);
        float lit = sat(dot(normalize(float3(q, sqrt(max(1.0 - dot(q, q), 0.0)))), normalize(float3(-0.5, 0.3, 0.8))));
        float4 m = nz4(NZ, float3(q * 2.5, 7.0));
        float3 mc = mix(float3(0.75, 0.78, 0.85), pal(u, 0.5 + hue), 0.2) * (0.08 + 0.9 * lit) * (0.6 + 0.4 * smoothstep(0.1, 0.5, m.b));
        col = mix(col, mc, disc);
        col += mc * exp(-max(r - R, 0.0) * 18.0) * 0.12;
    } else {                  // eclipse: dark disc, a corona of rays pulsing with the kick and sub
        R *= 1.4;
        float a = atan2(c.y, c.x);
        float rays = nfbm(NZ, float3(cos(a) * 3.0, sin(a) * 3.0, T * 0.15), 2);
        float cor = exp(-max(r - R, 0.0) * (14.0 - 6.0 * rays - 4.0 * kick)) * step(R, r);
        col += mix(sunC, acc(u, 0.3 + hue), 0.4) * cor * (0.5 + 0.6 * sub + 0.8 * kick);
        col *= 1.0 - smoothstep(R + px, R - px, r) * 0.97;
    }

    // Aurora: curtains above the horizon, rising with the voice (strongest at night).
    if (y > 0.0) {
        float2 ring = normalize(rd.xz + 1e-5);   // around the horizon on a circle: no seam behind the camera
        float n = nfbm(NZ, float3(ring * 5.0, T * 0.12), 2);
        float curtain = smoothstep(0.45, 0.75, n) * (0.6 + 0.4 * nz4(NZ, float3(ring * 40.0, T * 0.3 + 3.0)).g);
        float top = 0.2 + 0.25 * n + 0.2 * voice;
        float vert = smoothstep(0.04, 0.14, y) * smoothstep(top, top * 0.45, y);
        float3 ac = mix(acc(u, 0.35 + y * 2.0 + hue), pal(u, 0.9 + y + hue), sat(y * 3.0));
        col += ac * ac * curtain * vert * (0.02 + 0.5 * voice * voice) * (obj == 1 ? 2.0 : 1.0);
    }

    // Stars (mostly at night), twinkling with the hats / air.
    float3 sc = floor(rd * 300.0);
    float st = hash31(sc);
    col += step(0.997, st) * smoothstep(0.03, 0.2, y) * (obj == 1 ? 1.0 : 0.2) *
           (0.3 + 2.0 * air + u.hits.z) * (0.5 + 0.5 * sin(T * 6.0 + st * 100.0));

    // Clouds on a plane above: lit from behind by the sun on their edges.
    if (y > 0.005) {
        float2 cp = rd.xz / (y + 0.05);
        float cn = nfbm(NZ, float3(cp.x * 0.16 + T * 0.01, cp.y * 0.16 - T * 0.02, 1.0), 3);
        float cover = smoothstep(0.52, 0.78, cn) * smoothstep(0.04, 0.16, y) * (obj == 1 ? 0.5 : 0.85);
        float s = max(dot(rd, RIDGE_SUN), 0.0);
        float3 cc = ridgeAtmos(float3(rd.x, 0.02, rd.z), u) * 0.55 + sunC * (pow(s, 5.0) * 0.6) * (1.0 - smoothstep(0.6, 0.85, cn));
        col = mix(col, cc, cover);
    }
    return col;
}

// Anti-aliased line: d distance to the line, w half width, aa size of a pixel; keeps its energy
// below a pixel instead of breaking up.
static float lineAA(float d, float w, float aa) {
    float ww = max(w, 0.5 * aa);
    return (1.0 - smoothstep(ww - 0.5 * aa, ww + 0.5 * aa, d)) * (w / ww);
}

static float3 ridgeShade(float3 p, float3 rd, float t, float px, constant Frame& u,
                         texture2d<float> hist, sampler hs, NZP) {
    float hue = u.look.z, kick = u.hits.x, voice = u.bands.z, air = u.bands.w;
    float h = ridgeH(hist, hs, u, NZ, p.xz);
    float e = max(0.03, px * t);
    float3 n = normalize(float3(h - ridgeH(hist, hs, u, NZ, p.xz + float2(e, 0.0)), e,
                                h - ridgeH(hist, hs, u, NZ, p.xz + float2(0.0, e))));
    float edge;
    float f = ridgeFreq(u, p.x, edge);
    float ageS = ridgeAge(u, p.z);
    float age = sat(p.z / RIDGE_LEN);
    float3 wp = float3(p.x, p.y, p.z - ridgeScroll(u));   // texture space riding with the history
    float aa = px * t / max(abs(dot(n, rd)), 0.15);        // world size of a pixel on the surface
    float detail = smoothstep(0.12, 0.03, aa);             // fine texture fades out with distance
    int mat = geneI(u, 2, 4);

    // Detail normal from the noise volume (dunes get wind ripples instead).
    float3 bn = n;
    if (mat == 1) {
        float rw = nfbm(NZ, wp * 0.7, 2) * 7.0;
        float rp = cos(wp.z * 9.0 + wp.x * 2.0 + rw);
        bn = normalize(n + float3(0.0, 0.0, rp * 0.22 * detail));
    } else {
        const float be = 0.04;
        float b0 = nfbm(NZ, wp * 2.5, 2);
        float bx = nfbm(NZ, (wp + float3(be, 0.0, 0.0)) * 2.5, 2);
        float bz = nfbm(NZ, (wp + float3(0.0, 0.0, be)) * 2.5, 2);
        bn = normalize(n + float3(b0 - bx, 0.0, b0 - bz) / be * 0.12 * detail * (mat == 2 ? 0.5 : 1.0));
    }
    float rock = nfbm(NZ, wp * 1.3, 2);

    // Spectral colour: primary with the accent on one side of a frequency split.
    int cm = geneI(u, 5, 3);
    float ct = cm == 0 ? f * 0.9 + age * 0.3 : cm == 1 ? h * 0.35 + f * 0.15 : age * 0.9 + f * 0.2;
    float split = 0.25 + 0.5 * gene(u, 1);
    float3 lc = mix(pal(u, ct + hue), acc(u, ct * 0.7 + hue), smoothstep(split - 0.08, split + 0.08, f));
    lc = mix(lc, lc * lc * 1.6, 0.5);

    // Drum waves: every kick of the last seconds is a band of light at its age; snares in the accent.
    float kr = max(histScalar(hist, hs, u, 0, ageS) - 0.6 * histScalar(hist, hs, u, 0, ageS + 0.06), 0.0);
    float sr = max(histScalar(hist, hs, u, 1, ageS) - 0.6 * histScalar(hist, hs, u, 1, ageS + 0.06), 0.0);
    float3 sCol = acc(u, 0.3 + hue);
    float3 ec = mix(lc, sCol * sCol * 1.8 + 0.03, sat(sr * 2.0));
    float energy = sat(h * 0.55);
    float pulse = 1.0 + 2.5 * kr + 2.0 * sr + 1.2 * kick * exp(-age * 10.0) + 0.8 * u.rhythm.z * exp(-age * 5.0);
    float fadeBack = 1.0 - 0.5 * age;

    // Lighting: low sun (or moon) ahead, sky ambient, soft wrap diffuse.
    float3 sunC = ridgeSunCol(u);
    float diff = sat((dot(bn, RIDGE_SUN) + 0.25) / 1.25);
    float3 amb = ridgeAtmos(normalize(bn + float3(0.0, 1.0, 0.0)), u) * 1.4;
    float ao = sat(0.45 + 0.4 * (h + 0.3));
    float cosv = max(dot(bn, -rd), 0.0);
    float F = 0.04 + 0.96 * pow(1.0 - cosv, 5.0);
    float3 R = reflect(rd, bn);
    float sunSpec = pow(max(dot(R, RIDGE_SUN), 0.0), 24.0);

    float vd = 0.8 + 1.6 * gene(u, 0);   // vein / crack density
    float3 albedo, emis = float3(0.0), spec = float3(0.0);
    if (mat == 0) {           // bioluminescent moss: velvet, glowing veins that carry the spectrum
        albedo = mix(pal(u, 0.35 + hue), float3(0.08), 0.65) * 0.3 * (0.5 + rock);
        float wv = nz4(NZ, wp * vd).a;
        float vein = lineAA(wv, 0.025, aa * vd * 1.5);
        emis = ec * vein * (0.05 + 1.3 * energy) * pulse;
        float4 g = nz4(NZ, wp * 6.0);
        emis += ec * smoothstep(0.86, 0.96, g.g) * detail * (0.1 + 2.0 * air) * (0.3 + energy);
        spec = amb * pow(1.0 - cosv, 3.0) * 0.8;   // velvet sheen
    } else if (mat == 1) {    // dunes: sand ripples raking the low light, crests glowing with the spectrum
        albedo = mix(pal(u, 0.1 + hue), float3(0.55, 0.48, 0.4), 0.55) * 0.4 * (0.8 + 0.4 * rock);
        emis = ec * pow(energy, 2.5) * 0.9 * pulse;
        float4 g = nz4(NZ, wp * 9.0);
        spec = sunC * smoothstep(0.9, 0.97, g.g) * detail * (0.2 + 2.5 * air) + sunC * sunSpec * 0.15;
    } else if (mat == 2) {    // ice: glossy, lit from inside, cracks flashing with the drums
        albedo = mix(acc(u, 0.6 + hue), float3(0.3), 0.5) * 0.06;
        float thin = 1.0 - cosv;
        emis = ec * (0.04 + 0.9 * energy * energy) * (0.4 + 0.8 * thin) * pulse;
        float cr = lineAA(nz4(NZ, wp * vd * 0.7).a, 0.012, aa * vd);
        emis += mix(ec, float3(1.0), 0.3) * cr * (0.08 + 0.6 * energy) * pulse;
        spec = ridgeAtmos(R, u) * F * 1.5 + sunC * sunSpec * 0.6;
    } else {                  // lava crust: dark plates, glowing cracks, hot where the music is loud
        albedo = float3(0.05, 0.045, 0.045) * (0.5 + rock);
        float4 c4 = nz4(NZ, wp * vd * 0.6);
        float crack = lineAA(c4.a, 0.03 + 0.03 * energy, aa * vd);
        float3 hot = ec * ec * 1.8 + float3(0.05, 0.02, 0.0);
        emis = hot * crack * (0.1 + 1.6 * energy) * pulse;
        emis += hot * smoothstep(0.55, 0.95, energy) * (0.2 + 0.3 * (1.0 - c4.b)) * 0.5;   // molten peaks
        spec = sunC * sunSpec * 0.08;
    }
    // Glowing flakes on every material: short shards from the borders of a fine cell layer, broken up
    // by a second noise; brighter with the spectrum and the hats / air (ice has its own cracks).
    float flakeAmt = mat == 0 ? 0.6 : mat == 1 ? 1.5 : mat == 2 ? 0.0 : 0.5;
    if (flakeAmt > 0.0) {
        float fk = nz4(NZ, wp * 2.0 + 11.0).a;
        float flake = lineAA(fk, 0.012, aa * 2.0) * smoothstep(0.5, 0.7, nz4(NZ, wp * 0.8 + 5.0).g);
        emis += mix(ec, float3(1.0), 0.35) * flake * flakeAmt * (0.05 + 0.7 * energy + 1.5 * air) * pulse;
    }
    float3 surf = albedo * (sunC * diff * 0.9 + amb) * ao + spec + emis * fadeBack;
    surf += lc * kr * 0.03 * fadeBack;   // kick wave washes over the land too
    // The live edge: the cliff where "now" is written glows with the current spectrum, and the
    // newest strip of land behind it is still warm.
    float vNow = histSpec(hist, hs, u, pow(f, 0.85), 0.0).r;
    float face = smoothstep(-0.65, -0.25, p.z) * smoothstep(0.3, 0.0, p.z);
    float3 hotNow = mix(lc, lc * lc * 2.0 + 0.05, 0.5);
    surf += hotNow * face * (0.05 + 0.9 * vNow * vNow) * (1.0 + 0.7 * kick) * edge;
    surf += lc * exp(-max(p.z, 0.0) * 3.0) * smoothstep(-0.3, 0.1, p.z) * (0.05 + 0.6 * energy) * (0.5 + u.spec.w);
    return surf;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS, NOISE_ARGS) {
    float2 uv = screenUV(in, u);
    float hue = u.look.z, voice = u.bands.z, sub = u.bands.x, air = u.bands.w;

    // Camera presets: position.xyz and look-at z; every bar steps sideways and up (direction from a gene).
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 2.6, -5.5, 10.0), P1 = float4(0.0, 7.0, -4.0, 9.0), P2 = float4(-13.0, 6.5, 0.0, 4.5), P3 = float4(2.0, 2.8, -3.5, 7.0);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float dir = gene(u, 6) < 0.5 ? -1.0 : 1.0;
    float ph = u.hist.z * 1.5707963;
    float side = dir * 2.2 * sin(ph);
    float sway = sin(u.motion.z * 2.0) * 0.8;
    float3 ro = float3(C.x + sway + side, C.y - 0.25 * u.motion.w + 0.35 * (1.0 - cos(ph)), C.z);
    float3 ta = float3(sway * 0.3 + side * 0.35, 0.5, C.w);
    float3x3 cam = lookAt(ro, ta, u.cam.z * 0.25 + dir * 0.06 * sin(ph));
    float fov = 1.45 - 0.25 * u.cam.w;
    float3 rd = normalize(cam * float3(uv, fov));
    float px = 1.0 / (u.res.y * fov);

    // Primary ray; with the lake on, a ray that reaches the water first is reflected once.
    bool lake = gene(u, 3) > 0.45;
    float floorY = lake ? RIDGE_WATER : -10.0;
    float t = ridgeMarch(ro, rd, 110, 60.0, floorY, u, hist, hs, NZ);
    float3 pre = float3(0.0), thru = float3(1.0);
    float3 o = ro, d = rd;
    float tTot = 0.0;
    if (t < 0.0 && lake && rd.y < 0.0) {
        float tw = (RIDGE_WATER - ro.y) / rd.y;
        float3 pw = ro + rd * tw;
        float4 a = nz4(NZ, float3(pw.x * 1.3, pw.z * 1.3, u.res.z * 0.25));
        float4 b = nz4(NZ, float3(pw.x * 4.0 + 3.0, pw.z * 4.0, u.res.z * 0.5 + 2.0));
        float amp = (0.05 + 0.18 * sub) * smoothstep(0.12, 0.02, px * tw / max(-rd.y, 0.02));   // footprint along the grazing direction
        float3 wn = normalize(float3((a.r - 0.5) * amp + (b.g - 0.5) * amp * 0.4, 1.0, (a.g - 0.5) * amp + (b.r - 0.5) * amp * 0.4));
        float cosv = max(dot(wn, -rd), 0.0);
        float F = 0.04 + 0.96 * pow(1.0 - cosv, 5.0);
        float3 waterCol = ridgeAtmos(float3(0.0, 0.3, 1.0), u);
        pre = waterCol * 0.05;
        thru = float3(mix(0.12, 0.7, F));
        o = pw + wn * 0.01;
        d = reflect(rd, wn);
        d.y = max(d.y, 0.002);
        tTot = tw;
        t = ridgeMarch(o, d, 60, 40.0, -10.0, u, hist, hs, NZ);
    }

    float3 col;
    if (t >= 0.0) {
        tTot += t;
        float3 surf = ridgeShade(o + d * t, d, tTot, px, u, hist, hs, NZ);
        // Aerial perspective: the land fades into the colour of the sky behind it.
        col = mix(ridgeAtmos(d, u), surf, exp(-max(tTot - 8.0, 0.0) * 0.032) * smoothstep(58.0, 42.0, tTot));
    } else {
        col = ridgeSky(d, px, u, NZ);
        tTot = 60.0;
    }
    col = pre + thru * col;

    // Valley mist: thicker low down and far away, glowing with the voice.
    float3 mc = mix(acc(u, 0.45 + hue), ridgeSunCol(u), 0.3);
    float yAvg = ro.y + rd.y * min(tTot, 25.0) * 0.5;
    float mist = (1.0 - exp(-min(tTot, 40.0) * 0.035)) * exp(-max(yAvg, 0.0) * 0.5);
    col += mc * mc * mist * (0.01 + 0.12 * voice);

    // Drifting spores: a few depth layers of points rising slowly, flickering with the hats / air.
    float3 drift = float3(sin(u.res.z * 0.1) * 0.5, -u.res.z * 0.12, -u.res.z * 0.3);
    float3 so = ro + drift;
    for (int k = 0; k < 4; ++k) {
        float tk = 2.0 + float(k) * 3.0;
        if (tk > tTot) break;
        const float cs = 1.6;
        float3 cell = floor((so + rd * tk) / cs);
        float3 hsh = hash33(cell);
        if (hsh.x < 0.55) continue;
        float3 pt = (cell + 0.2 + 0.6 * hsh) * cs;
        float tp = dot(pt - so, rd);
        if (tp <= 0.0 || tp > tTot) continue;
        float dd = length(cross(pt - so, rd));
        float w = max(0.012, px * tp);
        float g = (0.012 / w) * (0.012 / w) * exp(-dd * dd / (w * w));
        float fl = 0.5 + 0.5 * sin(u.res.z * (3.0 + 4.0 * hsh.y) + hsh.z * 40.0);
        float3 spc = hsh.y > 0.5 ? acc(u, hsh.z + hue) : pal(u, hsh.z + hue);
        col += spc * g * fl * (0.15 + 2.0 * air + 1.0 * u.hits.z) * exp(-tp * 0.08);
    }
    return float4(col, 1.0);
}
