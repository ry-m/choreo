#include "Wav.h"

#if defined(__APPLE__)
#include <AudioToolbox/AudioToolbox.h>

namespace choreo {

// Decodes anything Core Audio understands (MP3, AAC/M4A, WAV, AIFF, FLAC, ...) to mono float.
bool loadAudioMono(const std::string& path, std::vector<float>& out, double& sampleRate) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(path.c_str()),
                                                           CFIndex(path.size()), false);
    ExtAudioFileRef file = nullptr;
    OSStatus err = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (err != noErr) return loadWavMono(path, out, sampleRate);

    AudioStreamBasicDescription in{};
    UInt32 size = sizeof(in);
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &in);
    sampleRate = in.mSampleRate;
    const UInt32 ch = std::max<UInt32>(1, in.mChannelsPerFrame);

    AudioStreamBasicDescription client{};
    client.mSampleRate = in.mSampleRate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    client.mChannelsPerFrame = ch;
    client.mBitsPerChannel = 32;
    client.mFramesPerPacket = 1;
    client.mBytesPerFrame = client.mBytesPerPacket = 4 * ch;
    if (ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client) != noErr) {
        ExtAudioFileDispose(file);
        return false;
    }

    out.clear();
    std::vector<float> buf(4096 * ch);
    for (;;) {
        UInt32 frames = 4096;
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = ch;
        abl.mBuffers[0].mDataByteSize = UInt32(buf.size() * sizeof(float));
        abl.mBuffers[0].mData = buf.data();
        if (ExtAudioFileRead(file, &frames, &abl) != noErr || frames == 0) break;
        for (UInt32 i = 0; i < frames; ++i) {
            float s = 0;
            for (UInt32 c = 0; c < ch; ++c) s += buf[i * ch + c];
            out.push_back(s / ch);
        }
    }
    ExtAudioFileDispose(file);
    return !out.empty();
}

} // namespace choreo

#else

namespace choreo {
bool loadAudioMono(const std::string& path, std::vector<float>& out, double& sampleRate) {
    return loadWavMono(path, out, sampleRate);
}
} // namespace choreo

#endif
