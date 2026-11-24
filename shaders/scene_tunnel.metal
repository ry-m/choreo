// Scene "Kaleido Tunnel": a raymarched kaleidoscopic fractal corridor with volumetric neon glow.
//   kick   -> the folds breathe, the lens punches, and a ring of light runs away down the walls
//             (one ring per kick of the last few seconds, read from the music history)
//   snare  -> the tunnel twists; a chromatic ring sweeps in
//   voice  -> (sustained mids) the helix of light along the axis swells and lights the walls
//   hats / air -> etched circuit lines in the metal glint
//   bass   -> the walls close in; builds -> faster folds, more twist
// Remix genes: 0 symmetry (5/7/9 sectors), 1 fold offsets, 2 fold angle, 3 plate shape,
// 4 tunnel radius, 5 colour mapping (orbit trap vs. depth), 6 roll direction, 7 helix strands.
// Camera: travel along the axis (speed from energy and kicks), a roll step on every bar.

struct TunnelHit { float d; float id; float trap; };

constant float TUNNEL_RING_SPEED = 9.0;   // kick rings run away down the walls, units per second

static TunnelHit tunnelMap(float3 p, constant Frame& u) {
    float kick = u.hits.x, bass = u.spec.x;
    p.xy = rot(p.z * 0.07 + u.motion.y) * p.xy;

    float3 q = p;
    float cell = floor(q.z / 3.0);
    q.z = modf1(q.z, 3.0) - 1.5;

    // Kaleidoscope around the tunnel axis.
    float sectors = float(5 + 2 * geneI(u, 0, 3));
    float ang = atan2(q.y, q.x), r = length(q.xy);
    float sa = TAU / sectors;
    ang = modf1(ang + sa * 0.5, sa) - sa * 0.5;
    q.xy = float2(cos(ang), sin(ang)) * r;
    q.x -= 3.0 + 0.5 * gene(u, 4) - 0.6 * bass - 0.4 * u.fx.z;

    // Folding IFS: crisp, crystalline structure that breathes with the kick. The orbit trap (closest
    // approach to the fold origin) colours the surfaces.
    float s = 1.0, trap = 1e3;
    float3 off = mix(float3(0.7, 1.0, 0.55), float3(0.95, 0.65, 0.8), gene(u, 1)) * (1.0 + 0.35 * kick);
    float fa = 0.45 + 0.35 * gene(u, 2) + 0.1 * sin(cell + u.res.z * 0.2) + 0.15 * u.dyn.z;
    for (int i = 0; i < 4; ++i) {
        q = abs(q) - off;
        q.xy = rot(fa) * q.xy;
        q.xz = rot(0.35) * q.xz;
        q *= 1.45; s *= 1.45;
        trap = min(trap, length(q.xz) / s);
    }
    float3 bx = mix(float3(0.5, 0.12, 0.5), float3(0.3, 0.3, 0.75), gene(u, 3));
    TunnelHit h; h.d = sdBox(q, bx) / s; h.id = cell; h.trap = trap;
    return h;
}

// Glow from the helix of light along the axis (not a surface: it only adds light).
static float helixGlow(float3 p, constant Frame& u) {
    float strands = 1.0 + floor(gene(u, 7) * 3.0);
    float a = atan2(p.y, p.x), r = length(p.xy);
    float rh = 0.18 + 0.35 * u.bands.z + 0.1 * u.hits.x;
    // Distance to the nearest strand, approximated in (angle, radius) at this depth.
    float phase = p.z * 1.4 - u.res.z * 3.0;
    float da = abs(modf1(a * strands - phase * strands + 3.14159, TAU) - 3.14159) / strands;
    float d = length(float2(da * max(r, 0.05), r - rh));
    return 0.004 / (0.004 + d * d) ;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS, NOISE_ARGS) {
    float2 uv = screenUV(in, u);
    float kick = u.hits.x, snare = u.hits.y, beatPulse = u.rhythm.z, hue = u.look.z;
    float voice = u.bands.z, air = u.bands.w;

    // Lens punch on kick, slight barrel distortion.
    uv *= 1.0 - 0.08 * kick;
    uv *= 1.0 + 0.15 * dot(uv, uv);

    // Camera: on the axis (off-axis puts the lens inside the walls); presets roll a quarter turn and
    // change the lens; every bar adds a roll step (direction from a gene), plus a gentle wander of aim.
    float pr = u.cam.x;
    float3 ro = float3(0.0, 0.0, u.motion.x * 2.0);
    float lens = 1.1 + 0.25 * sin(pr * 3.14159);
    float wob = u.res.z * 0.31;
    float3 rd = normalize(float3(uv + 0.06 * float2(sin(wob), cos(wob * 1.3)), lens - 0.25 * u.spec.w - 0.3 * u.cam.w));
    float rollDir = gene(u, 6) < 0.5 ? -1.0 : 1.0;
    rd.xy = rot(0.1 * sin(u.res.z * 0.3) + u.cam.z * 0.5 + pr * 0.785 + rollDir * 0.45 * u.hist.z) * rd.xy;

    float t = 0.0;
    // Glow is accumulated as a weight plus weighted palette coordinates; the palettes are evaluated once.
    float gw = 0.0, gT = 0.0, gD = 0.0, hglow = 0.0;
    bool hit = false;
    TunnelHit h;
    int steps = 0;
    for (int i = 0; i < 52; ++i) {
        float3 p = ro + rd * t;
        h = tunnelMap(p, u);
        float dd = max(abs(h.d), 0.002);
        // Neon glow hugging the edges: primary near the camera, the accent further down the tunnel.
        float w = (0.006 / (0.006 + dd * dd * 80.0)) * exp(-t * 0.1);
        gw += w; gT += w * (h.trap * 2.0 + h.id * 0.13); gD += w * sat(t / 20.0);
        if ((i & 3) == 0 && t > 1.5) hglow += helixGlow(p, u) * exp(-t * 0.1) * min(t, 4.0);
        steps = i;
        if (h.d < 0.001) { hit = true; break; }
        t += h.d * 0.85;
        if (t > 26.0) break;
    }
    float3 gc = mix(pal(u, gT / max(gw, 1e-4) + hue), acc(u, gT / max(gw, 1e-4) * 0.7 + hue), (gD / max(gw, 1e-4)) * (0.3 + 0.6 * gene(u, 5)));
    float3 col = gc * gc * gw * 0.02 * (0.4 + 0.9 * u.spec.w + 0.9 * beatPulse);
    col += mix(float3(1.0, 0.95, 1.0), acc(u, 0.2 + hue), 0.6) * hglow * 0.05 * (0.3 + 2.0 * voice + 1.2 * kick);
    // A light at the far end of the tunnel: the focal point, swelling with the bass.
    float ca = sat(rd.z);
    float endLight = pow(ca, 900.0) * 1.5 + pow(ca, 160.0 - 80.0 * u.spec.x) * 0.35;
    float3 endCol = mix(pal(u, 0.1 + hue), float3(1.0), 0.3) * endLight * (0.4 + 1.2 * u.spec.x + 0.6 * u.fx.x);
    // Fog: the far end of the tunnel is lit in the accent colour.
    float3 fogCol = acc(u, 0.5 + hue);
    fogCol *= fogCol * 0.03 * (0.5 + u.dyn.x);

    if (hit) {
        float3 p = ro + rd * t;
        const float2 k = float2(1.0, -1.0) * 0.002;
        float3 n = normalize(k.xyy * tunnelMap(p + k.xyy, u).d + k.yyx * tunnelMap(p + k.yyx, u).d +
                             k.yxy * tunnelMap(p + k.yxy, u).d + k.xxx * tunnelMap(p + k.xxx, u).d);
        float ao = 1.0 - float(steps) / 52.0;
        float cosv = max(dot(n, -rd), 0.0);
        float fres = pow(1.0 - cosv, 3.0);

        // Material: anodised metal plates with etched circuit lines (Worley borders) and grain.
        float3 tp = p;
        tp.xy = rot(p.z * 0.07 + u.motion.y) * tp.xy;     // texture rides with the folds
        float4 nz = nz4(NZ, tp * 1.1);
        float4 nzf = nz4(NZ, tp * 7.0 + 3.0);
        float etch = 1.0 - smoothstep(0.0, 0.035 + 0.02 * air, nz.a);
        float colourT = mix(h.trap * 2.5, h.id * 0.13 + t * 0.02, gene(u, 5));
        // Two-tone: some plates (by orbit-trap band and tunnel cell) take the accent palette.
        float band = floor(h.trap * 3.0) + h.id * 3.0;
        bool accentPlate = hash11(band * 1.37 + u.look.y * 11.0) < 0.3 + 0.25 * gene(u, 3);
        float3 base = accentPlate ? acc(u, colourT * 0.6 + hue) : pal(u, colourT + hue + 0.5);
        base *= base * (0.55 + 0.45 * nzf.r);   // squared: deeper, more saturated than the raw palette

        // Lights: one riding just ahead of the camera, and the helix on the axis (voice).
        float3 lp = ro + float3(0.0, 0.0, 1.5);
        float3 ld = normalize(lp - p);
        float dl = length(lp - p);
        float diff = max(dot(n, ld), 0.0) / (1.0 + dl * dl * 0.04);
        float3 ax = normalize(float3(-p.xy, 0.0) + 1e-4);
        float diffAxis = max(dot(n, ax), 0.0) * (0.2 + 1.5 * voice + 0.8 * kick);
        float spec = pow(max(dot(reflect(-ld, n), -rd), 0.0), 24.0) * (0.3 + 0.7 * nzf.g);
        float3 surf = base * (0.06 + 0.7 * diff + 0.5 * diffAxis) * ao;
        surf += mix(float3(1.0), base * 2.0 + 0.2, 0.6) * spec * (0.6 + u.spec.y) * ao;
        surf += fogCol * 6.0 * fres;   // rim picks up the far light
        // Etched circuits glow in the accent colour, glinting on hats / air.
        float3 ec = accentPlate ? pal(u, nz.r + hue) : acc(u, nz.r + hue);
        surf += ec * etch * (0.35 + 2.0 * u.hits.z + 2.0 * air) * (0.4 + 0.6 * ao);
        // Kick rings: bright bands running away from the camera along the walls.
        float age = max(p.z - ro.z, 0.0) / TUNNEL_RING_SPEED;
        if (age < 2.5) {
            float kr = max(histScalar(hist, hs, u, 0, age) - 0.6 * histScalar(hist, hs, u, 0, age + 0.05), 0.0);
            surf += mix(pal(u, 0.1 + hue), acc(u, 0.4 + hue), 0.5) * kr * 2.5 * exp(-age * 1.2) * (0.4 + etch);
        }
        col += mix(surf, fogCol + endCol * 0.3, 1.0 - exp(-t * 0.11));
    } else {
        col += fogCol + endCol;
    }

    // Snare: chromatic ring sweeping in with the beat.
    float ring = exp(-pow((length(uv) - (1.0 - u.rhythm.x) * 1.2) * 18.0, 2.0));
    col += snare * ring * acc(u, hue + 0.3) * 1.2;
    return float4(col, 1.0);
}
