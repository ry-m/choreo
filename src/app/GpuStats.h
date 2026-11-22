#pragma once
namespace choreo {
// Whole-GPU utilisation in percent (all processes, including the compositor), from the GPU
// driver's IORegistry statistics. Returns -1 where unavailable (non-macOS, or no such key).
int gpuUtilizationPercent();
} // namespace choreo
