// System / per-app audio capture on macOS 14.2+ using Core Audio process taps.
// A tap (global, or limited to one app's processes) is wrapped in a private aggregate device,
// and an IOProc on that device receives the tapped audio.
#include "audio/Capture.h"

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <vector>
#include <cstdio>
#include <cmath>

namespace choreo {

namespace {

AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel) {
    return {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

NSString* defaultOutputUID() {
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    auto a = addr(kAudioHardwarePropertyDefaultSystemOutputDevice);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, &dev) != noErr) return nil;
    CFStringRef uid = nullptr;
    size = sizeof(uid);
    auto u = addr(kAudioDevicePropertyDeviceUID);
    if (AudioObjectGetPropertyData(dev, &u, 0, nullptr, &size, &uid) != noErr || !uid) return nil;
    return (__bridge_transfer NSString*)uid;
}

// Core Audio process objects whose bundle ID starts with `prefix` (an app and its helpers).
NSArray<NSNumber*>* processObjectsForBundle(const std::string& prefix) {
    NSMutableArray<NSNumber*>* result = [NSMutableArray array];
    auto la = addr(kAudioHardwarePropertyProcessObjectList);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &la, 0, nullptr, &size) != noErr) return result;
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &la, 0, nullptr, &size, ids.data()) != noErr) return result;
    NSString* want = [NSString stringWithUTF8String:prefix.c_str()];
    for (AudioObjectID obj : ids) {
        CFStringRef bid = nullptr;
        UInt32 bs = sizeof(bid);
        auto ba = addr(kAudioProcessPropertyBundleID);
        if (AudioObjectGetPropertyData(obj, &ba, 0, nullptr, &bs, &bid) != noErr || !bid) continue;
        NSString* b = (__bridge_transfer NSString*)bid;
        if ([b hasPrefix:want]) [result addObject:@(obj)];
    }
    return result;
}

class MacTapCapture final : public Capture {
public:
    // bundlePrefix empty = all system audio. mute = tapped audio is not sent to the speakers.
    MacTapCapture(std::string bundlePrefix = {}, bool mute = false) : bundle_(std::move(bundlePrefix)), mute_(mute) {}
    ~MacTapCapture() override { stop(); }

    bool start(RingBuffer* out) override {
        if (@available(macOS 14.2, *)) {
            out_ = out;
            CATapDescription* desc = nil;
            if (bundle_.empty()) {
                desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
            } else {
                NSArray<NSNumber*>* procs = processObjectsForBundle(bundle_);
                if (procs.count == 0) {
                    fprintf(stderr, "[choreo] no audio processes found for %s (is it running?)\n", bundle_.c_str());
                    return false;
                }
                desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:procs];
            }
            desc.name = @"Choreo";
            desc.privateTap = YES;
            desc.muteBehavior = mute_ ? CATapMuted : CATapUnmuted;
            OSStatus err = AudioHardwareCreateProcessTap(desc, &tap_);
            if (err != noErr) {
                fprintf(stderr, "[choreo] AudioHardwareCreateProcessTap failed (%d)\n", (int)err);
                return false;
            }

            AudioStreamBasicDescription fmt{};
            UInt32 size = sizeof(fmt);
            auto fa = addr(kAudioTapPropertyFormat);
            AudioObjectGetPropertyData(tap_, &fa, 0, nullptr, &size, &fmt);
            sampleRate_ = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48000.0;

            NSMutableDictionary* agg = [@{
                @kAudioAggregateDeviceNameKey: @"Choreo Tap",
                @kAudioAggregateDeviceUIDKey: [[NSUUID UUID] UUIDString],
                @kAudioAggregateDeviceIsPrivateKey: @YES,
                @kAudioAggregateDeviceIsStackedKey: @NO,
                @kAudioAggregateDeviceTapAutoStartKey: @YES,
                @kAudioAggregateDeviceTapListKey: @[ @{
                    @kAudioSubTapUIDKey: desc.UUID.UUIDString,
                    @kAudioSubTapDriftCompensationKey: @YES,
                } ],
            } mutableCopy];
            if (NSString* outUID = defaultOutputUID()) {
                agg[@kAudioAggregateDeviceMainSubDeviceKey] = outUID;
                agg[@kAudioAggregateDeviceSubDeviceListKey] = @[ @{ @kAudioSubDeviceUIDKey: outUID } ];
            }
            err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &agg_);
            if (err != noErr) {
                fprintf(stderr, "[choreo] AudioHardwareCreateAggregateDevice failed (%d)\n", (int)err);
                stop();
                return false;
            }

            // The IOProc delivers audio at the aggregate device's clock rate (driven by the
            // output device, e.g. 44.1 kHz), which may differ from the tap's reported format.
            Float64 devRate = 0;
            size = sizeof(devRate);
            auto ra = addr(kAudioDevicePropertyNominalSampleRate);
            if (AudioObjectGetPropertyData(agg_, &ra, 0, nullptr, &size, &devRate) == noErr && devRate > 0) {
                if (fmt.mSampleRate > 0 && std::fabs(devRate - fmt.mSampleRate) > 1)
                    fprintf(stderr, "[choreo] tap format %.0f Hz, device clock %.0f Hz — using device\n", fmt.mSampleRate, devRate);
                sampleRate_ = devRate;
            } else if (fmt.mSampleRate <= 0) {
                fprintf(stderr, "[choreo] warning: could not determine capture sample rate, assuming 48 kHz\n");
            }

            err = AudioDeviceCreateIOProcIDWithBlock(&proc_, agg_, nullptr,
                ^(const AudioTimeStamp*, const AudioBufferList* in, const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*) {
                    this->onAudio(in);
                });
            if (err != noErr || AudioDeviceStart(agg_, proc_) != noErr) {
                fprintf(stderr, "[choreo] Failed to start tap IOProc (%d)\n", (int)err);
                stop();
                return false;
            }
            return true;
        }
        fprintf(stderr, "[choreo] System audio capture needs macOS 14.2+\n");
        return false;
    }

    void stop() override {
        if (agg_ != kAudioObjectUnknown) {
            if (proc_) { AudioDeviceStop(agg_, proc_); AudioDeviceDestroyIOProcID(agg_, proc_); }
            AudioHardwareDestroyAggregateDevice(agg_);
        }
        if (@available(macOS 14.2, *)) {
            if (tap_ != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(tap_);
        }
        proc_ = nullptr;
        agg_ = tap_ = kAudioObjectUnknown;
    }

    double sampleRate() const override { return sampleRate_; }
    std::string name() const override {
        return bundle_.empty() ? "System audio (Core Audio tap)"
                               : "App audio: " + bundle_ + (mute_ ? " (muted)" : "");
    }

private:
    // Real-time thread: downmix to mono and push. Handles interleaved or planar float32.
    void onAudio(const AudioBufferList* in) {
        if (!in || in->mNumberBuffers == 0) return;
        const AudioBuffer& b0 = in->mBuffers[0];
        if (in->mNumberBuffers == 1) {
            UInt32 ch = b0.mNumberChannels ? b0.mNumberChannels : 1;
            UInt32 frames = b0.mDataByteSize / (sizeof(float) * ch);
            const float* src = static_cast<const float*>(b0.mData);
            if (!src) return;
            float mono[4096];
            UInt32 done = 0;
            while (done < frames) {
                UInt32 n = std::min<UInt32>(frames - done, 4096);
                for (UInt32 i = 0; i < n; ++i) {
                    float s = 0;
                    for (UInt32 c = 0; c < ch; ++c) s += src[(done + i) * ch + c];
                    mono[i] = s / ch;
                }
                out_->write(mono, n);
                done += n;
            }
        } else {
            UInt32 frames = b0.mDataByteSize / sizeof(float);
            UInt32 nb = in->mNumberBuffers;
            float mono[4096];
            UInt32 done = 0;
            while (done < frames) {
                UInt32 n = std::min<UInt32>(frames - done, 4096);
                for (UInt32 i = 0; i < n; ++i) {
                    float s = 0;
                    for (UInt32 c = 0; c < nb; ++c) s += static_cast<const float*>(in->mBuffers[c].mData)[done + i];
                    mono[i] = s / nb;
                }
                out_->write(mono, n);
                done += n;
            }
        }
    }

    std::string bundle_;
    bool mute_ = false;
    RingBuffer* out_ = nullptr;
    AudioObjectID tap_ = kAudioObjectUnknown;
    AudioObjectID agg_ = kAudioObjectUnknown;
    AudioDeviceIOProcID proc_ = nullptr;
    double sampleRate_ = 48000.0;
};

} // namespace

std::unique_ptr<Capture> createSystemCapture() { return std::make_unique<MacTapCapture>(); }
std::unique_ptr<Capture> createAppCapture(const std::string& bundlePrefix, bool mute) {
    return std::make_unique<MacTapCapture>(bundlePrefix, mute);
}

} // namespace choreo
