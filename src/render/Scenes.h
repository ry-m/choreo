#pragma once
// The scene library: one raymarched fragment shader per scene (shaders/scene_<id>.metal, compiled
// after shaders/common.metal), plus the look the director gives it: a palette family, a camera
// language and post-processing character. Palettes are cosine palettes, col(t) = a + b*cos(2π(c*t + d)).

namespace choreo {

struct CosinePalette { float a[3], b[3], c[3], d[3]; };

enum class CameraStyle {
    Orbit,   // slow orbit around a central object; section changes cut to a new orbit angle/height
    Rise,    // low, looking up; handheld shake from the bass; slow circling
    Flight,  // forward flight with roll impulses on snares
    Travel,  // tunnel travel along the axis, speed from energy, twist from snares
};

struct SceneInfo {
    const char* id;            // shader file shaders/scene_<id>.metal
    const char* name;
    CameraStyle camera;
    float trails;              // feedback strength 0..1 (how much the previous frame smears)
    float trailZoom;           // feedback zoom per frame (+ = trails stream outward)
    float bloom;               // bloom strength
    float chroma;              // chromatic aberration base amount
    float exposure;
    CosinePalette palettes[4]; // the scene's palette family; sections step through it
};

inline constexpr SceneInfo kScenes[] = {
    {"prism", "Prism Cathedral", CameraStyle::Orbit, 0.35f, 0.004f, 0.9f, 0.6f, 1.0f,
     {
         {{0.50f, 0.55f, 0.65f}, {0.45f, 0.40f, 0.35f}, {1.0f, 1.0f, 1.0f}, {0.55f, 0.65f, 0.80f}}, // ice / violet
         {{0.55f, 0.50f, 0.60f}, {0.45f, 0.45f, 0.40f}, {1.0f, 1.0f, 0.9f}, {0.80f, 0.55f, 0.95f}}, // rose quartz
         {{0.45f, 0.60f, 0.60f}, {0.40f, 0.40f, 0.45f}, {1.0f, 0.9f, 1.0f}, {0.40f, 0.60f, 0.70f}}, // aquamarine
         {{0.60f, 0.55f, 0.50f}, {0.40f, 0.40f, 0.45f}, {0.9f, 1.0f, 1.0f}, {0.10f, 0.30f, 0.65f}}, // gold / indigo
     }},
    {"ember", "Ember Bloom", CameraStyle::Rise, 0.55f, 0.002f, 1.1f, 0.35f, 0.95f,
     {
         // Fire palettes run hottest at t = 0 and fade to black by t = 0.5 (d = 0 for the channel that lasts longest).
         {{0.55f, 0.30f, 0.12f}, {0.50f, 0.32f, 0.12f}, {1.0f, 1.0f, 1.0f}, {0.00f, 0.08f, 0.18f}}, // classic fire
         {{0.30f, 0.40f, 0.60f}, {0.30f, 0.40f, 0.50f}, {1.0f, 1.0f, 1.0f}, {0.20f, 0.08f, 0.00f}}, // gas blue
         {{0.50f, 0.30f, 0.55f}, {0.50f, 0.30f, 0.45f}, {1.0f, 1.0f, 1.0f}, {0.06f, 0.25f, 0.00f}}, // violet flame
         {{0.60f, 0.25f, 0.50f}, {0.50f, 0.25f, 0.45f}, {1.0f, 1.0f, 1.0f}, {0.00f, 0.30f, 0.10f}}, // magenta plasma
     }},
    {"laser", "Laser Nebula", CameraStyle::Flight, 0.45f, -0.002f, 1.2f, 0.9f, 1.0f,
     {
         {{0.50f, 0.50f, 0.50f}, {0.50f, 0.50f, 0.50f}, {1.0f, 1.0f, 1.0f}, {0.80f, 0.90f, 0.30f}}, // magenta / cyan
         {{0.50f, 0.50f, 0.50f}, {0.50f, 0.50f, 0.50f}, {1.0f, 1.0f, 0.5f}, {0.30f, 0.20f, 0.20f}}, // green / violet
         {{0.50f, 0.45f, 0.55f}, {0.50f, 0.45f, 0.45f}, {1.0f, 1.0f, 1.0f}, {0.00f, 0.33f, 0.67f}}, // RGB club
         {{0.55f, 0.45f, 0.50f}, {0.45f, 0.45f, 0.50f}, {0.8f, 0.8f, 0.8f}, {0.95f, 0.10f, 0.55f}}, // sunset neon
     }},
    {"tunnel", "Kaleido Tunnel", CameraStyle::Travel, 0.40f, 0.006f, 1.0f, 0.7f, 1.0f,
     {
         {{0.45f, 0.35f, 0.50f}, {0.50f, 0.45f, 0.45f}, {1.0f, 1.0f, 1.0f}, {0.85f, 0.20f, 0.55f}}, // neon violet
         {{0.45f, 0.40f, 0.35f}, {0.50f, 0.45f, 0.40f}, {1.0f, 0.7f, 0.4f}, {0.00f, 0.15f, 0.20f}}, // amber
         {{0.35f, 0.45f, 0.50f}, {0.40f, 0.45f, 0.50f}, {1.0f, 1.0f, 1.0f}, {0.45f, 0.55f, 0.75f}}, // teal
         {{0.50f, 0.38f, 0.40f}, {0.50f, 0.42f, 0.42f}, {1.0f, 1.0f, 1.0f}, {0.95f, 0.40f, 0.10f}}, // coral
     }},
    {"ridge", "Spectral Ridge", CameraStyle::Flight, 0.30f, 0.0f, 1.0f, 0.5f, 1.0f,
     {
         {{0.50f, 0.50f, 0.50f}, {0.50f, 0.50f, 0.50f}, {1.0f, 1.0f, 1.0f}, {0.00f, 0.10f, 0.20f}}, // full spectrum
         {{0.50f, 0.40f, 0.55f}, {0.50f, 0.45f, 0.45f}, {0.8f, 0.8f, 0.8f}, {0.55f, 0.75f, 0.95f}}, // cyan / violet
         {{0.55f, 0.45f, 0.35f}, {0.45f, 0.40f, 0.35f}, {1.0f, 1.0f, 1.0f}, {0.95f, 0.10f, 0.20f}}, // amber / rose
         {{0.40f, 0.55f, 0.45f}, {0.40f, 0.45f, 0.40f}, {1.0f, 1.0f, 1.0f}, {0.30f, 0.45f, 0.60f}}, // mint / teal
     }},
    {"halo", "Bar Halo", CameraStyle::Orbit, 0.35f, 0.003f, 1.1f, 0.6f, 1.0f,
     {
         {{0.55f, 0.55f, 0.05f}, {0.45f, 0.45f, 0.00f}, {1.0f, 1.0f, 1.0f}, {0.50f, 0.00f, 0.00f}}, // classic LED: green -> yellow -> red
         {{0.40f, 0.45f, 0.60f}, {0.45f, 0.45f, 0.40f}, {1.0f, 1.0f, 1.0f}, {0.60f, 0.70f, 0.85f}}, // ice blue -> magenta
         {{0.50f, 0.50f, 0.50f}, {0.50f, 0.50f, 0.50f}, {1.0f, 1.0f, 1.0f}, {0.00f, 0.33f, 0.67f}}, // rainbow
         {{0.60f, 0.40f, 0.30f}, {0.40f, 0.40f, 0.35f}, {1.0f, 1.0f, 1.0f}, {0.05f, 0.20f, 0.40f}}, // sunset
     }},
    {"tide", "Chrome Tide", CameraStyle::Orbit, 0.25f, 0.0f, 0.9f, 0.4f, 1.0f,
     {
         {{0.50f, 0.45f, 0.55f}, {0.50f, 0.45f, 0.45f}, {1.0f, 1.0f, 1.0f}, {0.80f, 0.20f, 0.45f}}, // dusk violet
         {{0.45f, 0.55f, 0.50f}, {0.45f, 0.45f, 0.45f}, {1.0f, 1.0f, 1.0f}, {0.40f, 0.60f, 0.80f}}, // polar aurora
         {{0.60f, 0.45f, 0.35f}, {0.40f, 0.40f, 0.40f}, {1.0f, 1.0f, 1.0f}, {0.00f, 0.15f, 0.30f}}, // gold hour
         {{0.50f, 0.50f, 0.55f}, {0.50f, 0.45f, 0.45f}, {0.9f, 0.9f, 1.0f}, {0.60f, 0.30f, 0.90f}}, // neon noir
     }},
};
inline constexpr int kSceneCount = int(sizeof(kScenes) / sizeof(kScenes[0]));

} // namespace choreo
