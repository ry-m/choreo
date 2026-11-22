#pragma once

namespace choreo {

// Everything the visuals know about the music. Published once per analysis hop (~10 ms).
// All "pulse" values are 1.0 at the event and decay toward 0; levels are AGC-normalised to ~0..1.
struct MusicState {
    double time = 0;          // seconds of audio analysed

    // Rhythm
    float bpm = 120;
    float tempoConfidence = 0; // 0..1: how clearly one tempo beats the others
    float pulseClarity = 0;    // 0..1: how periodic the onsets are at all (low in beatless intros)
    bool  beatPresent = false; // a beat is clearly present; when false, no beats fire
    float beatActivation = 0;  // learned detector: how beat-like this moment is (0..1)
    float downbeatActivation = 0; // learned detector: how downbeat-like (bar start) this moment is
    float beatPhase = 0;       // 0..1 position within the current beat (predicted)
    int   beatCount = 0;
    bool  beat = false;        // a beat fired this hop
    float beatPulse = 0;
    // Bars (from the bar tracker; with no learned model these stay at their defaults)
    int   beatInBar = 0;       // 0 = downbeat (first beat of the bar)
    int   beatsPerBar = 4;     // meter: 3 or 4
    float barPhase = 0;        // 0..1 position within the bar
    bool  downbeat = false;    // a beat fired this hop and it starts a bar
    float barConfidence = 0;   // 0..1: how sure the tracker is about the bar position

    // Instrument-ish onsets
    float kick = 0, snare = 0, hat = 0;
    float onset = 0;           // overall onset strength (normalised)

    // Spectrum / dynamics
    float bass = 0, mid = 0, treble = 0;
    float loudness = 0;        // 0..1
    float energyRatio = 1;     // short-term / long-term energy (>1 = getting louder, drops spike it)
    float brightness = 0;      // spectral centroid, 0..1
    float novelty = 0;         // how different the last ~1 s sounds from the last ~6 s (timbre change)
};

} // namespace choreo
