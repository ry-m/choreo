#pragma once
#include <string>
#include <vector>

namespace choreo {
// Loads a PCM16/24/32 or float32 WAV file, downmixed to mono. Returns false on failure.
bool loadWavMono(const std::string& path, std::vector<float>& out, double& sampleRate);
} // namespace choreo

namespace choreo {
// Loads any supported audio file (MP3/M4A/WAV/AIFF/FLAC on macOS; WAV elsewhere), mono.
bool loadAudioMono(const std::string& path, std::vector<float>& out, double& sampleRate);
} // namespace choreo
