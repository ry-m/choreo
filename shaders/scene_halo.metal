// Scene "Bar Halo": the classic bar analyser as a monument. A ring of bars (32 bands, mirrored) stands
// on a reflective floor, glass housings lit from inside by LED segments, with peak-hold caps that fall
// slowly; a textured orb hovers in the middle and lights the bars. Variants: one ring, double ring
// (inner ring shows the spectrum ~0.5 s ago), a spiral, and the flat wall of the old-school screen.
//   kick   -> the orb punches, and each kick sends a shockwave ring out across the floor
//   snare  -> the top segments and the caps flash in the accent colour
//   voice  -> the orb's surface boils and glows, a nebula behind wakes up
//   hats / air -> glints on the floor, stars twinkle
//   sub    -> the orb swells, the ring widens
// Remix genes: 0 bar count (48/64/80), 1 bar shape (box / rounded tube / blade), 2 colour mode (LED
// meter / frequency rainbow / accent split), 3 floor (mirror / stone tiles / brushed grooves),
// 4 orb (plasma / crystal / eclipse), 5 segment pitch, 6 orbit direction, 7 cap style (block / bead).
// Camera: orbit; section changes move it (low / overhead / close / far); every bar swings the orbit.

constant float HALO_KICK_SPEED = 7.0;   // shockwave rings, units per second

struct HaloHit { float d; float id; float kind; float bh; };   // kind: 0 bar, 1 cap, 2 orb; bh bar height

static float haloN(constant Frame& u) { return 48.0 + 16.0 * float(geneI(u, 0, 3)); }
static float haloH(constant Frame& u) { return 3.2 * (1.0 + 0.3 * u.dyn.y); }
static float3 haloOrbC(constant Frame& u) { return float3(0.0, 1.3 + 0.2 * u.rhythm.z, 0.0); }
static float haloOrbR(constant Frame& u) { return 0.55 + 0.35 * u.bands.x + 0.15 * u.hits.x; }

// Band position 0..1 (low..high) of bar id: mirrored, bass meets bass and treble meets treble.
static float haloBandF(float id, float N) {
    float hn = N * 0.5;
    float b = id < hn ? id : N - 1.0 - id;
    return b / (hn - 1.0);
}
static float2 haloBand(texture2d<float> hist, sampler hs, constant Frame& u, float f, float age) {
    float4 s = hist.sample(hs, float2((f * 31.0 + 0.5) / HIST_COLS, histV(u, age)));
    return s.rg;   // level, peak cap
}

static float sdRoundBox(float3 p, float3 b, float r) {
    float3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

static HaloHit haloMap(float3 p, texture2d<float> hist, sampler hs, constant Frame& u) {
    int variant = int(floor(u.look.x + 0.5)) % 4;
    float N = haloN(u), H = haloH(u);
    int shape = geneI(u, 1, 3);
    bool bead = gene(u, 7) > 0.5;
    HaloHit h; h.d = 1e3; h.id = 0.0; h.kind = 0.0; h.bh = 0.0;

    h.d = length(p - haloOrbC(u)) - haloOrbR(u); h.kind = 2.0;

    for (int ring = 0; ring < (variant == 1 ? 2 : 1); ++ring) {
        float3 q;
        float id;
        float R = (ring == 0 ? 4.2 : 2.6) + 0.25 * u.bands.x;
        float age = ring == 0 ? 0.0 : 0.5;
        float wid;
        if (variant == 3) {
            float w = 16.6 / N;
            id = clamp(floor(p.x / w + N * 0.5), 0.0, N - 1.0);
            q = float3(p.x - (id - N * 0.5 + 0.5) * w, p.y, p.z);
            q = q.zyx;   // bars face the camera (local x = depth)
            wid = w * 0.38;
        } else {
            float sa = TAU / N;
            float a = atan2(p.z, p.x) + (ring == 1 ? sa * 0.5 : 0.0) + u.motion.y * (ring == 0 ? 0.15 : -0.25);
            id = floor(modf1(a, TAU) / sa);
            float al = modf1(a, sa) - sa * 0.5;
            float r = length(p.xz);
            if (variant == 2) R += id / N * 2.5 - 1.0;   // spiral
            q = float3(r * cos(al) - R, p.y, r * sin(al));
            wid = R * sa * 0.38;
        }
        float2 lv = haloBand(hist, hs, u, haloBandF(id, N), age);
        float bh = 0.06 + lv.x * lv.x * H;
        float3 bq = q - float3(0.0, bh * 0.5, 0.0);
        float bar;
        if (shape == 0)      bar = sdBox(bq, float3(0.09, bh * 0.5, wid));
        else if (shape == 1) bar = sdRoundBox(bq, float3(min(0.1, wid), bh * 0.5, min(0.1, wid)), min(0.1, wid) * 0.95);
        else                 bar = sdBox(bq, float3(0.16, bh * 0.5, wid * 0.4));   // blade: deep and thin
        float capY = 0.06 + lv.y * lv.y * H + 0.12;
        float cap = bead ? length(q - float3(0.0, capY, 0.0)) - min(0.085, wid * 1.1)
                         : sdBox(q - float3(0.0, capY, 0.0), float3(0.1, 0.02, wid + 0.01));
        if (bar < h.d) { h.d = bar; h.id = id; h.kind = 0.0; h.bh = bh; }
        if (cap < h.d) { h.d = cap; h.id = id; h.kind = 1.0; h.bh = bh; }
    }
    return h;
}

static float haloMarch(float3 ro, float3 rd, float tMax, int steps, texture2d<float> hist, sampler hs, constant Frame& u,
                       thread HaloHit& h, thread float& glow) {
    float t = 0.0;
    for (int i = 0; i < steps; ++i) {
        float3 p = ro + rd * t;
        h = haloMap(p, hist, hs, u);
        glow += exp(-h.d * 12.0) * 0.012;
        if (h.d < 0.001 * (1.0 + t)) return t;
        t += h.d * 0.85;
        if (t > tMax) break;
    }
    return -1.0;
}

// Backdrop: deep gradient, a faint nebula that wakes with the voice, stars on the hats / air.
static float3 haloSky(float3 rd, constant Frame& u, NZP) {
    float hue = u.look.z, voice = u.bands.z;
    float3 col = pal(u, 0.7 + hue) * 0.012 * (1.0 + 2.0 * sat(rd.y + 0.2));
    float n = nwarp(NZ, rd * 2.2 + float3(0.0, 0.0, u.res.z * 0.02), 1.2, 3);
    float3 nc = mix(acc(u, 0.6 + n * 0.5 + hue), pal(u, 0.3 + hue), smoothstep(0.4, 0.7, n));
    col += nc * nc * smoothstep(0.42, 0.85, n) * (0.025 + 0.12 * voice) * smoothstep(-0.3, 0.3, rd.y);
    // A distant band of light low around the horizon.
    col += pal(u, 0.35 + hue) * exp(-abs(rd.y - 0.02) * 25.0) * 0.04 * (0.5 + u.spec.w);
    float3 sc = floor(rd * 280.0);
    float st = hash31(sc);
    col += step(0.997, st) * smoothstep(-0.1, 0.3, rd.y) * (0.2 + 2.0 * u.bands.w + u.hits.z) * (0.5 + 0.5 * sin(u.res.z * 5.0 + st * 90.0));
    return col;
}

static float3 haloShade(float3 p, float3 rd, float t, float px, HaloHit h, texture2d<float> hist, sampler hs,
                        constant Frame& u, NZP) {
    float hue = u.look.z, kick = u.hits.x, snare = u.hits.y, voice = u.bands.z;
    float3 oc = haloOrbC(u);
    float3 orbCol = mix(pal(u, 0.25 + hue), acc(u, 0.1 + hue), 0.3);
    if (h.kind > 1.5) {
        float3 n = normalize(p - oc);
        float cosv = sat(dot(n, -rd));
        float rim = pow(1.0 - cosv, 2.0);
        float T = u.res.z;
        int style = geneI(u, 4, 3);
        float pump = 0.6 + 2.5 * kick + 1.0 * u.bands.x;
        if (style == 0) {         // plasma: boiling bands, veins lighting up with the voice
            float b = nwarp(NZ, n * 2.2 + float3(0.0, T * 0.25, T * 0.1), 1.5 + 2.0 * voice, 3);
            float v = nridge(NZ, n * 3.0 + float3(T * 0.3, 0.0, 0.0), 3);
            float3 c = mix(pal(u, 0.2 + b * 0.6 + hue), acc(u, 0.1 + b + hue), smoothstep(0.35, 0.65, b));
            return c * c * (0.3 + 1.6 * b) * pump + acc(u, 0.5 + hue) * pow(v, 4.0) * (0.3 + 3.0 * voice) + orbCol * rim * 1.5;
        } else if (style == 1) {  // crystal: facets with bright seams
            float4 f = nz4(NZ, n * 2.5 + float3(0.0, T * 0.05, 0.0));
            float facet = 0.5 + 0.5 * sin(f.b * 20.0);
            float seam = 1.0 - smoothstep(0.0, 0.06, f.a);
            float3 c = mix(orbCol, acc(u, f.b + hue), 0.4);
            return c * (0.2 + 0.7 * facet) * pump * 0.6 + mix(c, float3(1.0), 0.5) * seam * (0.5 + 2.0 * voice + kick) + orbCol * rim;
        } else {                  // eclipse: dark core, blazing rim and a thin equator ring
            float eq = exp(-abs(n.y + 0.15 * sin(atan2(n.z, n.x) * 2.0 + T)) * 40.0);
            float3 c = mix(orbCol, acc(u, 0.4 + hue), 0.5);
            return c * 0.03 + orbCol * pow(1.0 - cosv, 3.0) * 4.0 * pump * 0.5 + c * eq * (0.6 + 2.0 * voice + 1.5 * kick);
        }
    }

    float N = haloN(u), H = haloH(u);
    float f = haloBandF(h.id, N);
    float3 sn = acc(u, 0.3 + hue);
    float y = p.y / H;
    int cm = geneI(u, 2, 3);
    float3 c;
    if (cm == 0) {        // LED meter: colour climbs with height, the accent on the top
        c = mix(pal(u, y * 0.5 + f * 0.05 + hue), acc(u, y * 0.3 + hue), smoothstep(0.6, 0.9, y));
    } else if (cm == 1) { // frequency rainbow, a little lift with height
        c = pal(u, f * 0.85 + y * 0.15 + hue);
    } else {              // accent split: low bands primary, high bands accent
        c = mix(pal(u, y * 0.4 + hue), acc(u, y * 0.4 + 0.2 + hue), smoothstep(0.4, 0.6, f));
    }
    c = mix(c, c * c * 1.5, 0.4);
    if (h.kind > 0.5) {   // peak cap: the bar's top colour, hotter; the accent on the snare
        float3 cc = (c * 1.1 + 0.04) * (0.6 + 0.4 * u.rhythm.z);
        return mix(cc, sn * sn * 2.0 + 0.08, sat(snare * 1.5));
    }

    // Glass housing lit from inside by LED segments (filtered: thin gaps melt to their average).
    float pitch = 6.0 + 4.0 * gene(u, 5);
    float sx = p.y * pitch;
    float fw = px * t * pitch * 1.5 + 1e-3;
    float sf = fract(sx);
    float seg = smoothstep(0.22 - fw, 0.22 + fw, sf) * (1.0 - smoothstep(1.0 - fw, 1.0, sf));
    seg = mix(seg, 0.78, sat(fw * 2.0 - 0.3));

    float top = smoothstep(h.bh - 0.5, h.bh - 0.05, p.y);   // the top segments flash on the snare
    c = mix(c, sn * sn * 2.0 + 0.05, sat(snare * 1.3) * top);
    // Housing normal from the map: the LEDs show through the side walls, the tops are plain glass.
    const float2 k = float2(1.0, -1.0) * 0.002;
    float3 n = normalize(k.xyy * haloMap(p + k.xyy, hist, hs, u).d + k.yyx * haloMap(p + k.yyx, hist, hs, u).d +
                         k.yxy * haloMap(p + k.yxy, hist, hs, u).d + k.xxx * haloMap(p + k.xxx, hist, hs, u).d);
    float side = 1.0 - smoothstep(0.5, 0.9, abs(n.y));
    float frost = 0.8 + 0.4 * nz4(NZ, p * 6.0).r;
    float3 col = c * seg * frost * side * (0.35 + 0.3 * u.rhythm.z + 0.5 * kick + 0.3 * top) + c * (0.04 + 0.12 * (1.0 - side));

    // The orb lights the housing, the sky reflects in the glass.
    float3 lo = oc - p;
    float dl = length(lo);
    float ol = max(dot(n, lo / dl), 0.0) / (1.0 + dl * dl * 0.06);
    col += orbCol * ol * 0.25 * (0.4 + 1.5 * kick + u.bands.x);
    float F = 0.04 + 0.96 * pow(1.0 - sat(dot(n, -rd)), 5.0);
    col += haloSky(reflect(rd, n), u, NZ) * F * 3.0;
    return col;
}

fragment float4 fmain(VOut in [[stage_in]], constant Frame& u [[buffer(0)]], HIST_ARGS, NOISE_ARGS) {
    float2 uv = screenUV(in, u);
    float hue = u.look.z, kick = u.hits.x;
    int variant = int(floor(u.look.x + 0.5)) % 4;

    // Orbit presets: angle offset, height, distance, look-at height. Every bar swings the orbit.
    float pr = u.cam.x;
    float4 P0 = float4(0.0, 4.2, 9.5, 0.6), P1 = float4(1.2, 9.5, 5.5, 0.0), P2 = float4(2.6, 2.6, 8.5, 1.4), P3 = float4(4.0, 6.0, 12.5, 0.8);
    float fi = floor(pr), ff = smoothstep(0.0, 1.0, fract(pr));
    int i0 = int(fi) % 4, i1 = (int(fi) + 1) % 4;
    float4 A = i0 == 0 ? P0 : i0 == 1 ? P1 : i0 == 2 ? P2 : P3;
    float4 Bp = i1 == 0 ? P0 : i1 == 1 ? P1 : i1 == 2 ? P2 : P3;
    float4 C = mix(A, Bp, ff);
    float dir = gene(u, 6) < 0.5 ? -1.0 : 1.0;
    float bars = u.hist.z;
    float ang = C.x + u.motion.z * (variant == 3 ? 0.0 : 1.0) + dir * 0.6 * bars - 1.5708;
    float dist = C.z * (1.0 - 0.06 * u.motion.w);
    float hgt = C.y + 0.6 * sin(bars * 1.5707963);
    // The flat wall is always seen from the front (the old screen view), stepping sideways each bar.
    float3 ro = variant == 3 ? float3(sin(u.motion.z * 0.7) * 3.0 + 2.0 * sin(bars * 1.5707963) * dir, 1.6 + 0.6 * hgt / 9.5, -11.0 * (1.0 - 0.06 * u.motion.w))
                             : float3(cos(ang) * dist, hgt, sin(ang) * dist);
    float3 ta = variant == 3 ? float3(0.0, 1.5, 0.0) : float3(0.0, C.w, 0.0);
    float3x3 cam = lookAt(ro, ta, u.cam.z * 0.2 + dir * 0.05 * sin(bars * 1.5707963));
    float fov = 1.5 - 0.25 * u.cam.w;
    float3 rd = normalize(cam * float3(uv, fov));
    float px = 1.0 / (u.res.y * fov);

    float3 col = haloSky(rd, u, NZ);
    float glow = 0.0;
    HaloHit h;
    float tFloor = rd.y < 0.0 ? -ro.y / rd.y : 1e3;
    float t = haloMarch(ro, rd, min(tFloor, 40.0), 90, hist, hs, u, h, glow);
    float3 o = ro, d = rd;
    float3 pre = float3(0.0), thru = float3(1.0);
    float tl = t, tTot = t;   // distance along the final ray, and in total (for the pixel footprint)
    if (t < 0.0 && tFloor < 1e3) {
        // Floor: reflective, with a texture per gene; kick shockwaves race outward across it.
        float3 p = ro + rd * tFloor;
        float r = length(p.xz);
        float fpx = px * tFloor / max(-rd.y, 0.05);   // floor footprint
        int fm = geneI(u, 3, 3);
        float3 fn = float3(0.0, 1.0, 0.0);
        float refl = 1.0;
        float3 base = float3(0.0);
        if (fm == 1) {        // stone tiles: polished slabs, darker seams, each slab its own sheen
            float4 c4 = nz4(NZ, float3(p.xz * 0.7, 1.5));
            float seam = 1.0 - smoothstep(0.0, 0.05 + fpx * 0.7, c4.a);
            float slab = hash11(floor(c4.b * 40.0));
            refl = mix(0.45 + 0.5 * slab, 0.05, seam);
            base = pal(u, 0.6 + hue) * 0.01 * (0.6 + nfbm(NZ, float3(p.xz * 3.0, 0.5), 2)) + acc(u, 0.4 + hue) * seam * 0.004;
        } else if (fm == 2) { // brushed grooves around the centre: an anisotropic sheen
            float g = 0.5 + 0.5 * sin(r * 90.0);
            float gfade = smoothstep(0.03, 0.005, fpx);
            refl = 0.45 + 0.25 * g * gfade;
            float2 tang = normalize(float2(-p.z, p.x) + 1e-4);
            float aniso = pow(1.0 - abs(dot(normalize(rd.xz + 1e-4), tang)), 6.0);
            base = pal(u, 0.3 + hue) * aniso * 0.05 * (0.5 + u.spec.w);
            fn = normalize(float3(p.x, 0.0, p.z) * (g - 0.5) * 0.02 * gfade / max(r, 0.1) + float3(0.0, 1.0, 0.0));
        } else {              // black mirror with faint rings
            float dr = abs(fract(r * 0.5 + 0.5) - 0.5) * 2.0;
            float gl = 1.0 - smoothstep(0.015, 0.015 + fpx * 1.5, dr);
            base = pal(u, 0.55 + hue) * gl * 0.12 * (0.4 + u.rhythm.z) * exp(-r * 0.08);
        }
        // Kick shockwaves: one ring per kick of the last seconds.
        float age = r / HALO_KICK_SPEED;
        float kr = max(histScalar(hist, hs, u, 0, age) - 0.6 * histScalar(hist, hs, u, 0, age + 0.04), 0.0);
        float3 kc = mix(pal(u, 0.1 + hue), acc(u, 0.4 + hue), 0.5);
        base += kc * kr * 0.8 * exp(-age * 0.8);
        // Glints on the hats / air.
        float4 g4 = nz4(NZ, float3(p.xz * 5.0, u.res.z * 0.3));
        base += mix(float3(1.0), acc(u, g4.r + hue), 0.5) * smoothstep(0.9, 0.97, g4.g) * (0.1 + 3.0 * u.bands.w) * smoothstep(0.05, 0.01, fpx);
        // The orb's light pools on the floor.
        float3 orbCol = mix(pal(u, 0.25 + hue), acc(u, 0.1 + hue), 0.3);
        base += orbCol * exp(-r * 0.6) * 0.12 * (0.5 + u.bands.x + 1.5 * kick);

        float fres = 0.25 + 0.75 * pow(1.0 - sat(-rd.y), 4.0);
        pre = base;
        thru = float3(fres * 0.7 * refl);
        o = p + fn * 0.01;
        d = reflect(rd, fn);
        float g2 = 0.0;
        tl = haloMarch(o, d, 20.0, 48, hist, hs, u, h, g2);
        tTot = tFloor + tl;
        glow += g2 * 0.4;
        col = haloSky(d, u, NZ) * 0.5;
    }
    if (tl > 0.0) col = haloShade(o + d * tl, d, tTot, px, h, hist, hs, u, NZ);
    col = pre + thru * col;
    col += pal(u, 0.35 + hue) * glow * (0.5 + u.spec.w);
    return float4(col, 1.0);
}
