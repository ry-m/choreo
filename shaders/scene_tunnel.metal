// Scene "Kaleido Tunnel": raymarched kaleidoscopic fractal corridor with volumetric neon glow.
// Camera: travel along the axis (speed from energy and kicks), twist from snares.

struct TunnelHit { float d; float id; };

static TunnelHit tunnelMap(float3 p, constant Frame& u) {
    float kick = u.hits.x, bass = u.spec.x;
    int variant = int(floor(u.look.x + 0.5));
    p.xy = rot(p.z * 0.07 + u.motion.y) * p.xy;

    float3 q = p;
    float cell = floor(q.z / 3.0);
    q.z = modf1(q.z, 3.0) - 1.5;

    // Kaleidoscope around the tunnel axis; the variant picks the symmetry.
    float sectors = float(5 + 2 * (variant % 3));
    float ang = atan2(q.y, q.x), r = length(q.xy);
    float sa = TAU / sectors;
    ang = modf1(ang + sa * 0.5, sa) - sa * 0.5;
    q.xy = float2(cos(ang), sin(ang)) * r;
    q.x -= 3.2 - 0.6 * bass - 0.4 * u.fx.z;

    // Folding IFS: crisp, crystalline structure that breathes with the kick.
    float s = 1.0;
    float3 off = float3(0.7, 1.0, 0.55) * (1.0 + 0.35 * kick);
    for (int i = 0; i < 4; ++i) {
        q = abs(q) - off;
        q.xy = rot(0.6 + 0.1 * sin(cell + u.res.z * 0.2) + 0.15 * u.dyn.z) * q.xy;
        q.xz = rot(0.35) * q.xz;
        q *= 1.45; s *= 1.45;
    }
    float d = sdBox(q, float3(0.5, 0.12, 0.5)) / s;

    // Central energy filament.
    float fil = length(p.xy + 0.15 * float2(sin(p.z * 1.3), cos(p.z * 1.1))) - (0.03 + 0.08 * kick);
    fil = max(fil, u.motion.x * 2.0 + 2.0 - p.z);  // not right in front of the lens (the camera is on the axis)
    TunnelHit h; h.d = d; h.id = cell;
    if (fil < d) { h.d = fil; h.id = -1.0; }
    return h;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]]) {
    float2 uv = screenUV(in, u);
    float kick = u.hits.x, snare = u.hits.y, beatPulse = u.rhythm.z, hue = u.look.z;

    // Lens punch on kick, slight barrel distortion.
    uv *= 1.0 - 0.08 * kick;
    uv *= 1.0 + 0.15 * dot(uv, uv);

    // Camera presets: a quarter turn of roll each, plus a wide or narrow lens (always on the axis:
    // off-axis puts the lens inside the walls).
    float pr = u.cam.x;
    float3 ro = float3(0.0, 0.0, u.motion.x * 2.0);
    float lens = 1.1 + 0.25 * sin(pr * 3.14159);
    float3 rd = normalize(float3(uv, lens - 0.25 * u.spec.w - 0.3 * u.cam.w));
    rd.xy = rot(0.1 * sin(u.res.z * 0.3) + u.cam.z * 0.5 + pr * 0.785) * rd.xy;

    float t = 0.0;
    float3 col = float3(0.0);
    bool hit = false;
    TunnelHit h;
    for (int i = 0; i < 56; ++i) {
        float3 p = ro + rd * t;
        h = tunnelMap(p, u);
        float dd = max(abs(h.d), 0.002);
        // Volumetric glow: accumulate light near surfaces, tinted by depth.
        float3 gc = h.id < 0.0 ? float3(1.0, 0.9, 1.0) * (0.6 + 2.0 * kick) : pal(u, h.id * 0.13 + p.z * 0.02 + hue);
        col += gc * (0.012 / (0.02 + dd * dd * 40.0)) * exp(-t * 0.08);
        if (h.d < 0.001) { hit = true; break; }
        t += h.d * 0.85;
        if (t > 26.0) break;
    }
    col *= 0.035 * (0.6 + 1.0 * u.spec.w + 0.8 * beatPulse);

    if (hit) {
        float3 p = ro + rd * t;
        const float2 k = float2(1.0, -1.0) * 0.002;
        float3 n = normalize(k.xyy * tunnelMap(p + k.xyy, u).d + k.yyx * tunnelMap(p + k.yyx, u).d +
                             k.yxy * tunnelMap(p + k.yxy, u).d + k.xxx * tunnelMap(p + k.xxx, u).d);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
        float3 base = pal(u, h.id * 0.13 + hue + 0.5);
        col += base * (0.1 + 0.7 * fres) * exp(-t * 0.07) * (0.4 + 0.8 * u.spec.y);
    }

    // Hats: sparkle. Snare: chromatic ring sweeping in with the beat.
    float n = hash21(in.uv * u.res.xy + u.res.z);
    col += u.hits.z * 0.6 * step(0.985, n) * float3(0.8, 0.9, 1.0);
    float ring = exp(-pow((length(uv) - (1.0 - u.rhythm.x) * 1.2) * 18.0, 2.0));
    col += snare * ring * pal(u, hue + 0.3) * 1.2;
    return float4(col, 1.0);
}
