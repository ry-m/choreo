#pragma once
#include <string>
#include <vector>

namespace choreo {

// Streaming inference for the learned beat/downbeat detector (tools/ml/train_beats.py).
// A causal temporal convolutional network: input conv, residual dilated blocks
// (conv k=3 dilation d -> ELU -> 1x1 conv, + skip), 1x1 output conv, sigmoid.
// Each push() consumes one 100 fps feature frame and returns the beat and downbeat
// activations for the frame `lookahead()` frames earlier.
class BeatNet {
public:
    bool load(const std::string& path);
    bool loaded() const { return loaded_; }
    int lookahead() const { return lookahead_; }
    void reset();
    // feat: inputDim() floats. out[0] = beat, out[1] = downbeat, both 0..1.
    void push(const float* feat, float out[2]);
    int inputDim() const { return dim_; }

private:
    struct Conv {
        int cin = 0, cout = 0, k = 1, d = 1;
        std::vector<float> w, b;      // w[o][c][j] (PyTorch Conv1d layout)
        std::vector<float> hist;      // ring of the last (k-1)*d+1 inputs, each cin floats
        int pos = 0;
        void init(int ci, int co, int kk, int dd);
        void step(const float* x, float* y); // push input x (cin), write output y (cout)
    };
    bool loaded_ = false;
    int dim_ = 0, ch_ = 0, lookahead_ = 0;
    Conv inp_, out_;
    std::vector<Conv> conv_, mix_;
    std::vector<float> h_, t_, u_;
};

} // namespace choreo
