// Scene "Chrome Tide": a sea of liquid metal under a living sky. Every kick of the last few seconds is
// a ring on the surface (a ring's radius is its age, read straight from the kick history), snares ripple
// from two sources off to the sides, the sub lifts a slow swell. The current spectrum stands along the
// horizon (aurora curtains or pillars of light), mirrored in the liquid.
//   kick   -> rings run out from the centre, their crests glow; the centrepiece dips; the sun flares
//   snare  -> side ripples; in the storm sky, lightning
//   voice  -> the aurora brightens and a glowing mist lies on the water
//   hats / air -> sun glitter sparkles on the wavelets, stars twinkle
// Remix genes: 0 sky (dusk sun / moonlit night / storm), 1 spectrum (curtains / pillars / none),
// 2 liquid (chrome / gold / black mercury / oil film), 3 wind (calm mirror .. choppy), 4 ring speed,
// 5 centrepiece (none / chrome sphere / obelisk), 6 orbit direction, 7 spectrum colours (palette / accent split).
// Camera: low orbit on the near side of the centre (sky ahead); presets change height and distance;
// every bar swings it.

constant float TIDE_SNARE_SPEED = 4.0;
constant float3 TIDE_SUN = float3(0.0, 0.0995, 0.995);

static float tideKickSpeed(constant Frame& u) { return 2.6 + 1.4 * gene(u, 4); }

static float tideRing(texture2d<float> hist, sampler hs, constant Frame& u, int col, float r, float speed, float amp,
                      float fade = 0.45, float maxAge = 4.1) {
    float age = r / speed;
    if (age > maxAge) return 0.0;
    // A smooth crest at each hit with a trough on either side (difference of the history at three ages).
    float a = histScalar(hist, hs, u, col, age);
    float b = histScalar(hist, hs, u, col, age + 0.08) + histScalar(hist, hs, u, col, max(age - 0.08, 0.0));
    return (a - 0.5 * b) * amp * exp(-age * fade) / (1.0 + r * 0.08) * smoothstep(maxAge, maxAge * 0.7, age);
}

static float tideH(texture2d<float> hist, sampler hs, constant Frame& u, float2 xz) {
    float t = u.res.z;
    float h = tideRing(hist, hs, u, 0, length(xz), tideKickSpeed(u), 0.3 * (0.6 + u.dyn.y));
    // Snare rings die out within ~1.5 s: grown huge they look like straight lines and cross into a grid.
    h += tideRing(hist, hs, u, 1, length(xz - float2(-7.0, 6.0)), TIDE_SNARE_SPEED, 0.2, 1.6, 1.5);
    h += tideRing(hist, hs, u, 1, length(xz - float2(7.0, 6.0)), TIDE_SNARE_SPEED, 0.2, 1.6, 1.5);
    // Swell: sums of travelling waves in off-axis directions (products of sines would print a grid).
    h += (0.04 + 0.12 * u.bands.x) * (sin(dot(xz, float2(0.27, 0.21)) + t * 1.1) + sin(dot(xz, float2(-0.19, 0.31)) - t * 0.8));
    h += 0.018 * (sin(dot(xz, float2(1.13, 0.62)) - t * 1.9) + sin(dot(xz, float2(-0.71, 1.07)) + t * 1.6));
    return h;
}

static float3 tideSunCol(constant Frame& u) { return mix(pal(u, 0.08 + u.look.z), float3(1.0, 0.9, 0.8), 0.3); }

static float3 tideSky(float3 rd, texture2d<float> hist, sampler hs, constant Frame& u, NZP, bool reflected) {
    float hue = u.look.z, kick = u.hits.x, snare = u.hits.y, voice = u.bands.z, air = u.bands.w, sub = u.bands.x;
    float T = u.res.z;
    float y = rd.y;
    int mode = geneI(u, 0, 3);   // 0 dusk, 1 night, 2 storm
    float3 hor = mix(pal(u, 0.55 + hue), acc(u, 0.9 + hue), 0.25);
    hor *= hor * (mode == 0 ? 0.16 : mode == 1 ? 0.05 : 0.07);
    float3 zen = mix(pal(u, 0.75 + hue), acc(u, 0.6 + hue), 0.5);
    zen *= zen * (mode == 1 ? 0.03 : 0.1);
    float3 col = mix(hor, zen, sat(pow(max(y, 0.0) * 2.2, 0.7)));
    float s = sat(dot(rd, TIDE_SUN));
    float3 sunC = tideSunCol(u);
    float az = atan2(rd.x, rd.z);

    if (mode == 0) {          // low sun, flaring with the kick
        col += sunC * (pow(s, 600.0) * 10.0 + pow(s, 40.0) * 0.3 * (0.5 + sub) + pow(s, 4.0) * 0.04) * (1.0 + 0.8 * kick);
    } else if (mode == 1) {   // moon and stars
        float m = smoothstep(0.9993, 0.9996, s);
        float3 mc = mix(float3(0.8, 0.82, 0.9), pal(u, 0.5 + hue), 0.2);
        col = mix(col, mc * (0.7 + 0.3 * nz4(NZ, rd * 60.0).b), m) + mc * pow(s, 60.0) * 0.06;
        float3 sc = floor(rd * 300.0);
        float st = hash31(sc);
        col += step(0.996, st) * smoothstep(0.02, 0.2, y) * (0.3 + 2.0 * air + u.hits.z) * (0.5 + 0.5 * sin(T * 6.0 + st * 100.0));
    } else {                  // storm: the sun only a smudge behind the clouds
        col += sunC * pow(s, 8.0) * 0.05;
    }

    // The spectrum along the horizon: frequency mirrored around the view ahead, bass straight ahead.
    int am = geneI(u, 1, 3);
    if (am < 2 && y > -0.01) {
        float f = abs(fract(az / TAU * 1.5 + 0.5) - 0.5) * 2.0;
        bool split = gene(u, 7) > 0.5;
        if (am == 0) {        // aurora curtains: folds swaying, soft rays, a glowing fringe at the peaks
            float wv = nfbm(NZ, float3(az * 4.0, T * 0.15, 1.0), 2);
            float fw = sat(f + (wv - 0.5) * 0.08);
            float4 sp = histSpec(hist, hs, u, fw, 0.0);
            float top = 0.03 + sp.r * sp.r * 0.5, peak = 0.03 + sp.g * sp.g * 0.5;
            float curtain = smoothstep(top, top - 0.2, y) * smoothstep(-0.005, 0.04, y);
            float rays = reflected ? 0.8 : 0.5 + 0.8 * nz4(NZ, float3(az * 25.0, y * 1.5, T * 0.3)).r;
            float3 c = split ? mix(pal(u, 0.1 + y + hue), acc(u, 0.2 + y + hue), smoothstep(0.35, 0.65, fw))
                             : mix(pal(u, fw * 0.6 + 0.1 + hue), acc(u, y * 1.5 + hue), smoothstep(0.0, 0.4, y));
            c *= c * 1.6;
            col += c * curtain * rays * (0.1 + 0.6 * sp.r) * (0.6 + 0.4 * u.dyn.x + 0.8 * voice);
            col += c * exp(-pow((y - peak) / 0.07, 2.0)) * (0.03 + 0.15 * sp.g) * smoothstep(-0.01, 0.03, y);   // soft glow at the peaks
        } else {              // pillars of light, one per band, mirrored in the liquid as long streaks
            float bf = f * 31.0;
            float bi = floor(bf + 0.5);
            float4 sp = histSpec(hist, hs, u, bi / 31.0, 0.0);
            float top = 0.02 + sp.r * sp.r * 0.45;
            float w = abs(bf - bi);
            float pil = (1.0 - smoothstep(0.12, 0.35, w)) * smoothstep(top, top * 0.6, y) * smoothstep(-0.01, 0.005, y);
            float3 c = split ? mix(pal(u, 0.15 + y + hue), acc(u, 0.25 + y + hue), step(0.5, bi / 31.0))
                             : mix(pal(u, bi / 31.0 * 0.7 + hue), acc(u, y * 2.0 + hue), smoothstep(0.0, 0.3, y));
            c *= c * 1.6;
            col += c * pil * (0.15 + 0.9 * sp.r) * (0.7 + 0.8 * voice);
            col += c * exp(-max(w - 0.1, 0.0) * 6.0) * exp(-abs(y) * 30.0) * 0.06 * (0.3 + sp.r);   // glow at the foot
        }
    }

    // Clouds on a plane above; the storm's are thick and lit from inside by lightning on the snare.
    if (y > 0.0) {
        float2 cp = rd.xz / (y + 0.06);
        float cn = nfbm(NZ, float3(cp.x * 0.18 + T * 0.01, cp.y * 0.18 - T * 0.02, 1.0), reflected ? 2 : 3);
        float lo = mode == 2 ? 0.32 : mode == 1 ? 0.6 : 0.52;
        float cover = smoothstep(lo, lo + 0.25, cn) * smoothstep(0.02, 0.12, y) * (mode == 2 ? 0.95 : 0.75);
        float3 cc = hor * 0.6 + sunC * pow(s, 5.0) * 0.5 * (mode == 0 ? 1.0 : 0.1);
        if (mode == 2) {
            // Lightning: a bolt somewhere ahead, its position re-rolled every half second.
            float seed = floor(T * 2.0);
            float azB = (hash11(seed) - 0.5) * 1.6;
            float fl = snare * snare * step(0.3, hash11(seed + 7.0));
            float3 lc = mix(float3(0.75, 0.8, 1.0), acc(u, 0.5 + hue), 0.3);
            cc += lc * exp(-pow((az - azB) * 2.5, 2.0)) * fl * (0.4 + cn) * 0.8;
            col += lc * fl * 0.03;
            if (!reflected) {
                float x = azB + (nfbm(NZ, float3(y * 14.0, seed, 3.0), 3) - 0.5) * 0.25;
                float base = 0.12 + 0.1 * hash11(seed + 3.0);
                col += lc * exp(-abs(az - x) * 500.0) * fl * 3.0 * step(y, base);
            }
        }
        col = mix(col, cc, cover);
    }
    // Mist lying on the water, glowing with the voice.
    float3 mc = mix(acc(u, 0.45 + hue), sunC, 0.3);
    col += mc * mc * exp(-abs(y) * 18.0) * (0.01 + 0.15 * voice);
    return col;
}

// Centrepiece (analytic): 1 chrome sphere hovering over the ring centre, 2 obelisk standing in the sea.
static float tideObj(float3 ro, float3 rd, constant Frame& u, thread float3& n) {
    int obj = geneI(u, 5, 3);
    float T = u.res.z;
    if (obj == 1) {
        float3 c = float3(0.0, 1.4 + 0.2 * sin(T * 0.7) - 0.3 * u.hits.x, 0.0);
        float R = 0.85 + 0.2 * u.bands.x;
        float3 oc = ro - c;
        float b = dot(oc, rd), cc = dot(oc, oc) - R * R, disc = b * b - cc;
        if (disc < 0.0) return -1.0;
        float t = -b - sqrt(disc);
        if (t < 0.0) return -1.0;
        n = normalize(ro + rd * t - c);
        return t;
    } else if (obj == 2) {
        float a = T * 0.12;
        float2x2 m = rot(a);
        float3 lo = ro - float3(0.0, 1.5 - 0.15 * u.hits.x, 0.0);
        lo.xz = m * lo.xz;
        float3 ld = rd;
        ld.xz = m * ld.xz;
        float3 bh = float3(0.38, 2.0, 0.38);
        float3 inv = 1.0 / (ld + 1e-6);
        float3 t0 = (-bh - lo) * inv, t1 = (bh - lo) * inv;
        float3 tmin = min(t0, t1), tmax = max(t0, t1);
        float tn = max(max(tmin.x, tmin.y), tmin.z), tf = min(min(tmax.x, tmax.y), tmax.z);
        if (tn > tf || tn < 0.0) return -1.0;
        float3 ln = -sign(ld) * step(tmin.yzx, tmin) * step(tmin.zxy, tmin);
        ln.xz = transpose(m) * ln.xz;
        n = ln;
        return tn;
    }
    return -1.0;
}

static float3 tideObjShade(float3 p, float3 rd, float3 n, texture2d<float> hist, sampler hs, constant Frame& u, NZP) {
    float hue = u.look.z;
    int obj = geneI(u, 5, 3);
    float3 r = reflect(rd, n);
    float F = 0.04 + 0.96 * pow(1.0 - sat(dot(n, -rd)), 5.0);
    // What the object sees: the sky above, the (approximately mirror-flat) sea below.
    float3 env = r.y > 0.0 ? tideSky(r, hist, hs, u, NZ, true)
                           : tideSky(float3(r.x, -r.y, r.z), hist, hs, u, NZ, true) * 0.55;
    if (obj == 1) {
        float3 tint = mix(float3(0.9), pal(u, 0.4 + hue), 0.25);
        return env * tint * (0.9 + 0.5 * F) + acc(u, 0.3 + hue) * pow(1.0 - sat(dot(n, -rd)), 3.0) * u.hits.x * 0.6;
    }
    // Obelisk: black glass with glyphs lit from inside on the beat.
    float3 q = p - float3(0.0, 1.5, 0.0);
    q.xz = rot(u.res.z * 0.12) * q.xz;
    float4 g = nz4(NZ, q * float3(2.2, 1.2, 2.2) + 9.0);
    float glyph = (1.0 - smoothstep(0.0, 0.05, g.a)) * step(0.45, g.r);
    float3 gc = mix(pal(u, 0.2 + q.y * 0.15 + hue), acc(u, 0.5 + hue), 0.5);
    float pump = 0.15 + 0.8 * u.rhythm.z + 1.5 * u.hits.x + 0.8 * u.bands.z;
    return env * (0.05 + 0.95 * F) + gc * gc * glyph * pump;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS, NOISE_ARGS) {
    float2 uv = screenUV(in, u);
    float hue = u.look.z, air = u.bands.w;
    float T = u.res.z;

    // Orbit presets: angle offset, height, distance, look-at height.
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 1.6, 9.0, 1.4), P1 = float4(1.4, 4.5, 9.0, 0.2), P2 = float4(3.1, 0.9, 6.5, 1.6), P3 = float4(4.4, 2.6, 14.0, 1.8);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    // The camera stays on the near side of the centre, so the sun and spectrum are ahead; every bar
    // swings it a little round the orbit and up.
    float dir = gene(u, 6) < 0.5 ? -1.0 : 1.0;
    float bars = u.hist.z;
    float ang = -1.5708 + 0.5 * sin(C.x + u.motion.z * 0.6) + dir * 0.3 * sin(bars * 1.5707963);
    float3 ro = float3(cos(ang) * C.z, C.y + 0.1 * sin(T * 0.5) + 0.35 * (1.0 - cos(bars * 1.5707963)), sin(ang) * C.z);
    float3 ta = float3(0.0, C.w, 6.0);
    float3x3 cam = lookAt(ro, ta, u.cam.z * 0.2 + 0.03 * sin(T * 0.4) + dir * 0.04 * sin(bars * 1.5707963));
    float fov = 1.4 - 0.25 * u.cam.w;
    float3 rd = normalize(cam * float3(uv, fov));
    float px = 1.0 / (u.res.y * fov);

    float3 on;
    float tO = tideObj(ro, rd, u, on);

    // Sea: heightfield march (the swell is gentle, so few steps), then bisection.
    float t = -1.0;
    if (rd.y < 0.02) {
        const float hMax = 0.9;
        float tt = rd.y < 0.0 ? max(0.0, (ro.y - hMax) / -rd.y) : 0.0, tPrev = tt;
        bool hit = false;
        for (int i = 0; i < 70 && tt < 80.0; ++i) {
            float3 p = ro + rd * tt;
            float dy = p.y - tideH(hist, hs, u, p.xz);
            if (dy < 0.002 * tt) { hit = true; break; }
            tPrev = tt;
            tt += max(dy * 0.6, 0.02 + tt * 0.01);
        }
        if (hit) {
            for (int i = 0; i < 5; ++i) {
                float tm = 0.5 * (tt + tPrev);
                float3 p = ro + rd * tm;
                if (p.y > tideH(hist, hs, u, p.xz)) tPrev = tm; else tt = tm;
            }
            t = tt;
        }
    }

    float3 col;
    if (tO > 0.0 && (t < 0.0 || tO < t)) {
        col = tideObjShade(ro + rd * tO, rd, on, hist, hs, u, NZ);
    } else if (t > 0.0) {
        float3 p = ro + rd * t;
        float e = 0.02 + t * 0.002;
        float h = tideH(hist, hs, u, p.xz);
        float3 n = normalize(float3(h - tideH(hist, hs, u, p.xz + float2(e, 0.0)), e, h - tideH(hist, hs, u, p.xz + float2(0.0, e))));
        // Wind ripples from the noise volume, fading out with distance (no sparkle aliasing far away).
        float fp = px * t / max(-rd.y, 0.04);
        float fade = smoothstep(0.15, 0.03, fp);
        float wind = 0.006 + 0.05 * gene(u, 3);
        float4 a = nz4(NZ, float3(p.xz * 1.2 + float2(T * 0.35, T * 0.2), T * 0.1));
        float4 b = nz4(NZ, float3(p.xz * 3.3 - float2(T * 0.25, -T * 0.45), T * 0.2 + 4.0));
        n = normalize(n + float3(a.r - 0.5 + 0.5 * (b.g - 0.5), 0.0, a.g - 0.5 + 0.5 * (b.r - 0.5)) * wind * 4.0 * fade);
        float3 rr = reflect(rd, n);
        rr.y = abs(rr.y);
        float cosv = sat(dot(n, -rd));
        float F = pow(1.0 - cosv, 5.0);
        int liq = geneI(u, 2, 4);
        float3 tint;
        float fres;
        if (liq == 0)      { tint = mix(float3(0.85), pal(u, 0.4 + hue) * 1.2, 0.25); fres = 0.55 + 0.45 * F; }
        else if (liq == 1) { tint = mix(float3(1.0, 0.76, 0.42), pal(u, 0.1 + hue), 0.2); fres = 0.55 + 0.45 * F; }
        else if (liq == 2) { tint = float3(0.3); fres = 0.15 + 0.85 * F; }
        else {               // oil film: thin-film colours with the angle and a slick of noise
            float th = cosv * 1.6 + a.b * 0.8;
            tint = mix(0.55 + 0.45 * cos(TAU * (th + float3(0.0, 0.33, 0.67) + hue)), pal(u, th + hue), 0.4) * 1.1;
            fres = 0.4 + 0.6 * F;
        }
        float3 on2;
        float tO2 = tideObj(p + n * 0.02, rr, u, on2);
        float3 env = tO2 > 0.0 ? tideObjShade(p + n * 0.02 + rr * tO2, rr, on2, hist, hs, u, NZ)
                               : tideSky(rr, hist, hs, u, NZ, true);
        float3 surf = env * tint * fres;
        // Sun (or moon) glitter on the wavelets, sparkling with the hats / air.
        float gl = smoothstep(0.85, 0.97, b.g) * pow(sat(dot(rr, TIDE_SUN)), 20.0) * fade;
        surf += tideSunCol(u) * gl * (0.3 + 3.0 * air + u.hits.z) * (geneI(u, 0, 3) == 2 ? 0.15 : 1.0);
        // Fresh kick rings glow from within (the crest that just left the centre).
        float3 crest = mix(pal(u, 0.1 + hue), acc(u, 0.4 + hue), sat(u.hits.y * 1.5));
        surf += crest * sat(h * 3.0) * 0.3 * exp(-length(p.xz) * 0.25);
        col = mix(tideSky(rd, hist, hs, u, NZ, false), surf, exp(-t * 0.02));
    } else {
        col = tideSky(rd, hist, hs, u, NZ, false);
    }
    return float4(col, 1.0);
}
