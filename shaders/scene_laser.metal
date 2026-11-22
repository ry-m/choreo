// Scene "Laser Nebula": flying low over a glossy neon grid toward a portal ring that fires fans of
// lasers through nebula haze. Beams sweep with the bar, flick on snares, strobe on hats at high
// intensity; the grid pulses rows toward the camera on each beat; the floor mirrors the beams.
// Camera: forward flight with roll; section changes move it (low / high / centre / side).
// Everything is analytic (no SDF march), which keeps this scene cheap.

// Distance between the ray (ro, rd) and the beam line (o, d), and the ray parameter of closest approach.
static float2 rayLine(float3 ro, float3 rd, float3 o, float3 d) {
    float3 w = ro - o;
    float b = dot(rd, d), dd = dot(rd, w), e = dot(d, w);
    float den = max(1.0 - b * b, 1e-4);
    float tr = (b * e - dd) / den;
    float tl = (e - b * dd) / den;
    if (tl <= 0.0) return float2(1e3, -1.0);  // closest point is behind the emitter
    return float2(length((ro + rd * tr) - (o + d * tl)), tr);
}

static float3 lasers(float3 ro, float3 rd, float tMax, constant Frame& u, float3 stage) {
    int variant = int(floor(u.look.x + 0.5)) % 4;
    float bar = u.rhythm.y, beat = u.rhythm.z, snare = u.hits.y, strobe = u.fx.w;
    float3 col = float3(0.0);
    const int N = 14;
    for (int i = 0; i < N; ++i) {
        float fi = float(i) / float(N - 1) - 0.5;
        float h = hash11(float(i) * 7.7 + u.look.y * 13.0);
        float sweep = sin(TAU * bar + fi * 3.0) * 0.6 + snare * (h - 0.5) * 1.2;
        float3 o = stage, d;
        if (variant == 0) {        // fan from the portal toward the camera
            d = normalize(float3(fi * 2.2 + sweep * 0.5, 0.25 * sin(u.res.z * 0.7 + fi * 4.0) + 0.05, -1.0));
        } else if (variant == 1) { // cross: two fans scissoring
            float s = i % 2 == 0 ? 1.0 : -1.0;
            d = normalize(float3(s * (fi + 0.5) * 1.6 * cos(TAU * bar), 0.3 + 0.4 * (fi + 0.5) * s * sin(TAU * bar), -1.0));
        } else if (variant == 2) { // cage: beams from a ring around the portal, converging behind the camera
            float a = fi * TAU + u.motion.y;
            o = stage + float3(cos(a), sin(a) + 1.0, 0.0) * 3.0;
            d = normalize(float3(-cos(a) * 0.15, -sin(a) * 0.15, -1.0));
        } else {                   // curtain: vertical sheet from above, sweeping sideways
            o = float3(stage.x + fi * 14.0 + sweep * 3.0, 9.0, stage.z - 12.0);
            d = normalize(float3(sin(fi * 5.0 + u.res.z) * 0.3, -1.0, 0.25));
        }
        float2 dl = rayLine(ro, rd, o, d);
        if (dl.y <= 0.0 || dl.y > tMax) continue;
        float dist = dl.x;
        float w = 0.012 + 0.006 * beat;
        float core = exp(-dist * dist / (w * w));
        float halo = 0.03 / (0.03 + dist * dist * 6.0);
        float on = 0.55 + 0.45 * sin(u.res.z * (2.0 + 3.0 * h) + h * 10.0);
        on = mix(on, step(0.5, fract(u.res.z * 12.0 + h)), strobe);  // hat strobe at high intensity
        float3 c = pal(u, h * 0.35 + float(i % 3) * 0.33 + u.look.z);
        col += c * (core * 6.0 + halo * 0.6) * on * (0.5 + 1.2 * u.dyn.y + 1.5 * beat) * exp(-dl.y * 0.025);
    }
    return col;
}

static float3 nebula(float3 rd, constant Frame& u, float travel) {
    float3 q = rd * 2.2 + float3(0.0, 0.0, travel * 0.01);
    float n = fbm3(q + float3(u.look.y * 10.0, 0.0, 0.0), 4);
    float n2 = fbm3(q * 1.7 + 4.0, 3);
    float3 col = pal(u, n * 0.8 + u.look.z + 0.2) * pow(sat(n - 0.35) * 1.8, 2.0) * 0.6;
    col += pal(u, n2 + 0.55) * pow(sat(n2 - 0.45) * 2.0, 3.0) * 0.4;
    float3 sc = floor(rd * 300.0);
    col += step(0.9975, hash31(sc)) * (0.5 + 2.0 * u.hits.z) * float3(0.9, 0.95, 1.0);
    return col * (0.6 + 0.6 * u.dyn.x);
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]]) {
    float2 uv = screenUV(in, u);
    float kick = u.hits.x, beat = u.rhythm.z;
    float travel = u.motion.x * 3.0;

    // Flight camera presets: (x, height, pitch, yaw).
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 0.6, 0.05, 0.0), P1 = float4(0.0, 3.5, -0.3, 0.0), P2 = float4(0.0, 1.6, 0.0, 0.0), P3 = float4(3.0, 1.0, 0.0, -0.25);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float3 ro = float3(C.x + 0.4 * sin(u.res.z * 0.21), C.y + 0.15 * sin(u.res.z * 0.37) - 0.1 * u.motion.w, travel);
    float3 fwd = normalize(float3(sin(C.w), C.z, cos(C.w)));
    float3x3 cam = lookAt(ro, ro + fwd, u.cam.z * 0.6 + 0.05 * sin(u.motion.y));
    float3 rd = normalize(cam * float3(uv, 1.25 - 0.3 * u.cam.w));
    float3 stage = float3(0.0, 2.2, travel + 38.0);

    float3 col = nebula(rd, u, travel);

    // Portal ring (vertical, facing the camera) far ahead, pulsing on kicks, expanding on hits.
    {
        float tp = (stage.z - ro.z) / max(rd.z, 1e-3);
        if (rd.z > 0.0) {
            float3 p = ro + rd * tp - stage;
            float R = 5.0 + 1.2 * kick + u.fx.y * 18.0 * exp(-u.fx.y);
            float d = abs(length(p.xy) - R);
            col += pal(u, 0.1 + u.look.z) * (0.05 / (0.05 + d * d * 2.0)) * (1.0 + 4.0 * kick + 1.0 * u.fx.x);
            col += pal(u, 0.6) * exp(-length(p.xy) * 0.3) * 0.2 * (1.0 + beat);
        }
    }

    // Floor: glossy black at y = 0 with a neon grid; rows of light run toward the camera each beat.
    float tMax = 200.0;
    if (rd.y < 0.0) {
        float tf = -ro.y / rd.y;
        tMax = tf;
        float3 p = ro + rd * tf;
        float2 g = p.xz * 0.25;
        float2 fw = fwidth(g) + 1e-4;
        float2 dl = 0.5 - abs(fract(g) - 0.5);                 // distance to the nearest grid line
        float2 gl = 1.0 - smoothstep(float2(0.0), fw * 1.5, dl);
        gl *= sat(0.3 / max(fw.x + fw.y, 1e-3));               // fade where lines get sub-pixel (no moire)
        float grid = max(gl.x, gl.y) * exp(-tf * 0.03);
        float row = fract((p.z - travel) * 0.05 + u.rhythm.x);
        float wave = exp(-pow((row - 0.5) * 9.0, 2.0)) * (0.3 + 1.5 * beat);
        float3 gc = pal(u, 0.55 + p.x * 0.01 + u.look.z);
        float3 floorCol = gc * grid * (0.12 + 1.6 * wave + 0.6 * u.spec.x);
        // Reflection of the beams and sky (fresnel), slightly blurred by distance.
        float3 rr = reflect(rd, float3(0.0, 1.0, 0.0));
        float fres = 0.1 + 0.9 * pow(1.0 - sat(-rd.y), 5.0);
        float3 refl = lasers(p + float3(0.0, 0.01, 0.0), rr, 200.0, u, stage) * 0.5 + nebula(rr, u, travel) * 0.2;
        col = floorCol + refl * fres;
    }
    col += lasers(ro, rd, tMax, u, stage);

    // Haze: fog toward the horizon tinted by the palette, brighter on kicks.
    float haze = exp(-abs(rd.y) * 7.0);
    col += pal(u, 0.75 + u.look.z) * haze * (0.1 + 0.25 * kick + 0.3 * u.dyn.z);
    return float4(col, 1.0);
}
