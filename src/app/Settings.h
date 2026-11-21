#pragma once
#include <SDL3/SDL.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace choreo {

// Tiny persistent settings (key=value lines) in the platform's per-user app data folder,
// e.g. ~/Library/Application Support/Choreo/settings.txt on macOS.
struct Settings {
    float visualDelayMs = 0.f; // user A/V calibration: + delays the visuals, - advances them

    static std::string path() {
        char* dir = SDL_GetPrefPath("Choreo", "Choreo");
        std::string p = dir ? std::string(dir) + "settings.txt" : "settings.txt";
        SDL_free(dir);
        return p;
    }
    void load() {
        if (std::FILE* f = std::fopen(path().c_str(), "r")) {
            char line[256];
            while (std::fgets(line, sizeof line, f))
                if (!std::strncmp(line, "visual_delay_ms=", 16)) visualDelayMs = float(std::atof(line + 16));
            std::fclose(f);
        }
    }
    void save() const {
        if (std::FILE* f = std::fopen(path().c_str(), "w")) {
            std::fprintf(f, "visual_delay_ms=%.1f\n", visualDelayMs);
            std::fclose(f);
        }
    }
};

} // namespace choreo
