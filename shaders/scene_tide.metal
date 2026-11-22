// Scene "Chrome Tide": a sea of liquid chrome. Every kick of the last few seconds is a ring on the
// surface (a ring's radius is its age, read straight from the kick history), snares ripple from two
// sources off to the sides, bass lifts a slow swell. The sky holds a spectrum aurora (current bands
// as glowing curtains along the horizon) and a pulsing sun, all mirrored in the chrome.
// Camera: low orbit around the ripple centre; presets change height and distance.

constant float TIDE_KICK_SPEED = 3.2;   // ring speed, units per second
constant float TIDE_SNARE_SPEED = 4.0;

static float tideRing(texture2d<float> hist, sampler hs, constant Frame& u, int col, float r, float speed, float amp,
                      float fade = 0.45, float maxAge = 4.1) {
    float age = r / speed;
    if (age > maxAge) return 0.0;
    // Crest at the kick, trough just behind it, fading as the ring spreads.
    // A smooth crest at each hit with a trough on either side (difference of the history at three ages).
    float a = histScalar(hist, hs, u, col, age);
    float b = histScalar(hist, hs, u, col, age + 0.08) + histScalar(hist, hs, u, col, max(age - 0.08, 0.0));
    return (a - 0.5 * b) * amp * exp(-age * fade) / (1.0 + r * 0.08) * smoothstep(maxAge, maxAge * 0.7, age);
}

static float tideH(texture2d<float> hist, sampler hs, constant Frame& u, float2 xz) {
    float t = u.res.z;
    float h = tideRing(hist, hs, u, 0, length(xz), TIDE_KICK_SPEED, 0.3 * (0.6 + u.dyn.y));
    // Snare rings die out within ~1.5 s: grown huge they look like straight lines and cross into a grid.
    h += tideRing(hist, hs, u, 1, length(xz - float2(-7.0, 6.0)), TIDE_SNARE_SPEED, 0.2, 1.6, 1.5);
    h += tideRing(hist, hs, u, 1, length(xz - float2(7.0, 6.0)), TIDE_SNARE_SPEED, 0.2, 1.6, 1.5);
    // Swell: sums of travelling waves in off-axis directions (products of sines would print a grid).
    h += (0.04 + 0.12 * u.spec.x) * (sin(dot(xz, float2(0.27, 0.21)) + t * 1.1) + sin(dot(xz, float2(-0.19, 0.31)) - t * 0.8));
    h += 0.018 * (sin(dot(xz, float2(1.13, 0.62)) - t * 1.9) + sin(dot(xz, float2(-0.71, 1.07)) + t * 1.6));
    return h;
}

static float3 tideSky(float3 rd, texture2d<float> hist, sampler hs, constant Frame& u, bool reflected = false) {
    float hue = u.look.z;
    float y = rd.y;
    float3 col = mix(pal(u, 0.55 + hue) * 0.12, pal(u, 0.75 + hue) * 0.015, sat(y * 2.2));
    // Spectrum aurora: frequency across the horizon (mirrored around the view ahead), band level =
    // curtain height. Soft vertical falloff and fine vertical rays.
    float az = atan2(rd.x, rd.z);
    float f = abs(fract(az / TAU * 1.5 + 0.5) - 0.5) * 2.0;
    float4 s = histSpec(hist, hs, u, f, 0.0);
    float top = 0.03 + s.r * s.r * 0.5;
    float curtain = smoothstep(top, top - 0.18, y) * smoothstep(0.0, 0.04, y);
    // Fine rays only when seen directly: mirrored in the near-flat chrome they print a lattice.
    float rays = reflected ? 0.8 : 0.6 + 0.4 * sin(az * 90.0 + u.res.z * 2.0);
    col += pal(u, f * 0.6 + hue + 0.1) * curtain * rays * (0.1 + 0.5 * s.r) * (0.5 + 0.5 * u.dyn.x);
    // Peak caps as a thin bright line above each curtain.
    float capY = 0.03 + s.g * s.g * 0.5;
    if (!reflected) col += pal(u, f * 0.6 + hue + 0.3) * exp(-pow((y - capY) * 120.0, 2.0)) * 0.8;
    // Sun low ahead, swelling with the bass, flashing with kicks.
    float3 sd = normalize(float3(0.0, 0.12, 1.0));
    float sun = sat(dot(rd, sd));
    col += pal(u, 0.08 + hue) * (pow(sun, 400.0) * 8.0 + pow(sun, 24.0) * 0.25 * (0.5 + u.spec.x)) * (1.0 + 1.5 * u.hits.x);
    return col;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS) {
    float2 uv = screenUV(in, u);
    float hue = u.look.z;

    // Orbit presets: angle offset, height, distance, look-at height.
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 1.6, 9.0, 1.4), P1 = float4(1.4, 4.5, 9.0, 0.2), P2 = float4(3.1, 0.8, 6.0, 1.6), P3 = float4(4.4, 2.6, 14.0, 1.8);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    // The camera stays on the near side of the centre, so the sun and aurora are ahead.
    float ang = -1.5708 + 0.5 * sin(C.x + u.motion.z * 0.6);
    float3 ro = float3(cos(ang) * C.z, C.y + 0.1 * sin(u.res.z * 0.5), sin(ang) * C.z);
    float3 ta = float3(0.0, C.w, 6.0);
    float3x3 cam = lookAt(ro, ta, u.cam.z * 0.2 + 0.03 * sin(u.res.z * 0.4));
    float3 rd = normalize(cam * float3(uv, 1.4 - 0.25 * u.cam.w));

    float3 col = tideSky(rd, hist, hs, u);
    if (rd.y < 0.02) {
        // Heightfield march (the swell is gentle, so few steps), then bisection.
        const float hMax = 0.9;
        float t = rd.y < 0.0 ? max(0.0, (ro.y - hMax) / -rd.y) : 0.0, tPrev = t;
        bool hit = false;
        for (int i = 0; i < 70 && t < 80.0; ++i) {
            float3 p = ro + rd * t;
            float dy = p.y - tideH(hist, hs, u, p.xz);
            if (dy < 0.002 * t) { hit = true; break; }
            tPrev = t;
            t += max(dy * 0.6, 0.02 + t * 0.01);
        }
        if (hit) {
            for (int i = 0; i < 5; ++i) {
                float tm = 0.5 * (t + tPrev);
                float3 p = ro + rd * tm;
                if (p.y > tideH(hist, hs, u, p.xz)) tPrev = tm; else t = tm;
            }
            float3 p = ro + rd * t;
            float e = 0.02 + t * 0.002;
            float h = tideH(hist, hs, u, p.xz);
            float3 n = normalize(float3(h - tideH(hist, hs, u, p.xz + float2(e, 0.0)), e, h - tideH(hist, hs, u, p.xz + float2(0.0, e))));
            // Fine capillary ripples in the normal only (smooth analytic waves; no effect on the march).
            float tt = u.res.z;
            float2 d1 = float2(0.83, 0.56), d2 = float2(-0.45, 0.89), d3 = float2(0.21, -0.98);
            float2 g = d1 * cos(dot(p.xz, d1) * 3.3 - tt * 2.3) + d2 * cos(dot(p.xz, d2) * 4.1 + tt * 1.9) + d3 * cos(dot(p.xz, d3) * 2.7 - tt * 1.4);
            n = normalize(n + float3(g.x, 0.0, g.y) * 0.012 * exp(-t * 0.12));
            float3 rr = reflect(rd, n);
            rr.y = abs(rr.y);
            float fres = 0.55 + 0.45 * pow(1.0 - sat(dot(n, -rd)), 5.0);
            float3 chrome = mix(float3(0.85), pal(u, 0.4 + hue) * 1.2, 0.25);
            float3 surf = tideSky(rr, hist, hs, u, true) * chrome * fres;
            // Fresh kick rings glow slightly from within (the crest that just left the centre).
            surf += pal(u, 0.1 + hue) * sat(h * 3.0) * 0.25 * exp(-length(p.xz) * 0.25);
            col = mix(tideSky(rd, hist, hs, u), surf, exp(-t * 0.02));
        }
    }
    return float4(col, 1.0);
}
