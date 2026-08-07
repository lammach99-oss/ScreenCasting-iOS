#include "OpusBridge.h"

#if __has_include(<opus/opus.h>)
#include <opus/opus.h>
#else
#include <opus.h>
#endif

#include <climits>
#include <atomic>
#include <mutex>
#include <new>

namespace {
constexpr int SampleRate = 48000;
constexpr int Channels = 2;
constexpr int FramesPerCall = 480;
std::atomic<UINT32> liveEncoderHandles{0};
std::atomic<UINT32> liveDecoderHandles{0};

HRESULT OpusResult(int code) {
    if (code == OPUS_OK) {
        return S_OK;
    }
    if (code == OPUS_ALLOC_FAIL) {
        return E_OUTOFMEMORY;
    }
    if (code == OPUS_BAD_ARG || code == OPUS_BUFFER_TOO_SMALL) {
        return E_INVALIDARG;
    }
    return E_FAIL;
}
} // namespace

struct OpusEncoderContext {
    OpusEncoder* encoder = nullptr;
    std::mutex gate;
};

struct OpusDecoderContext {
    OpusDecoder* decoder = nullptr;
    std::mutex gate;
};

extern "C" HRESULT CreateOpusEncoder(OpusEncoderHandle* output) {
    if (!output) {
        return E_INVALIDARG;
    }
    *output = nullptr;
    OpusEncoderContext* context = new (std::nothrow) OpusEncoderContext();
    if (!context) {
        return E_OUTOFMEMORY;
    }
    int error = OPUS_OK;
    context->encoder = opus_encoder_create(
        SampleRate, Channels, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error);
    if (!context->encoder || error != OPUS_OK) {
        delete context;
        return OpusResult(error);
    }
    if (opus_encoder_ctl(context->encoder, OPUS_SET_BITRATE(96000)) != OPUS_OK ||
        opus_encoder_ctl(context->encoder, OPUS_SET_VBR(1)) != OPUS_OK ||
        opus_encoder_ctl(context->encoder, OPUS_SET_VBR_CONSTRAINT(1)) != OPUS_OK ||
        opus_encoder_ctl(context->encoder, OPUS_SET_COMPLEXITY(5)) != OPUS_OK) {
        opus_encoder_destroy(context->encoder);
        delete context;
        return E_FAIL;
    }
    *output = context;
    liveEncoderHandles.fetch_add(1, std::memory_order_relaxed);
    return S_OK;
}

extern "C" HRESULT EncodeOpus(
    OpusEncoderHandle handle, const std::int16_t* pcm, UINT32 framesPerChannel,
    BYTE* packet, UINT32 capacity, UINT32* length) {
    if (!handle) {
        return E_HANDLE;
    }
    if (!pcm || framesPerChannel != FramesPerCall || !packet || !length ||
        capacity == 0 || capacity > INT_MAX) {
        return E_INVALIDARG;
    }
    *length = 0;
    std::lock_guard<std::mutex> lock(handle->gate);
    const int encoded = opus_encode(
        handle->encoder, pcm, FramesPerCall, packet, static_cast<int>(capacity));
    if (encoded < 0) {
        return encoded == OPUS_BUFFER_TOO_SMALL
            ? REALTIME_E_BUFFER_TOO_SMALL
            : OpusResult(encoded);
    }
    *length = static_cast<UINT32>(encoded);
    return S_OK;
}

extern "C" void DestroyOpusEncoder(OpusEncoderHandle handle) {
    if (!handle) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(handle->gate);
        opus_encoder_destroy(handle->encoder);
        handle->encoder = nullptr;
    }
    liveEncoderHandles.fetch_sub(1, std::memory_order_relaxed);
    delete handle;
}

extern "C" HRESULT CreateOpusDecoder(OpusDecoderHandle* output) {
    if (!output) {
        return E_INVALIDARG;
    }
    *output = nullptr;
    OpusDecoderContext* context = new (std::nothrow) OpusDecoderContext();
    if (!context) {
        return E_OUTOFMEMORY;
    }
    int error = OPUS_OK;
    context->decoder = opus_decoder_create(SampleRate, Channels, &error);
    if (!context->decoder || error != OPUS_OK) {
        delete context;
        return OpusResult(error);
    }
    *output = context;
    liveDecoderHandles.fetch_add(1, std::memory_order_relaxed);
    return S_OK;
}

extern "C" HRESULT DecodeOpus(
    OpusDecoderHandle handle, const BYTE* packet, UINT32 length,
    std::int16_t* pcm, UINT32 capacityFramesPerChannel,
    UINT32* decodedFramesPerChannel) {
    if (!handle) {
        return E_HANDLE;
    }
    if ((!packet && length != 0) || (packet && length == 0) || length > 1275 ||
        !pcm || capacityFramesPerChannel < FramesPerCall ||
        !decodedFramesPerChannel) {
        return E_INVALIDARG;
    }
    *decodedFramesPerChannel = 0;
    std::lock_guard<std::mutex> lock(handle->gate);
    const int decoded = opus_decode(
        handle->decoder, packet, static_cast<int>(length), pcm,
        FramesPerCall, 0);
    if (decoded < 0) {
        return OpusResult(decoded);
    }
    if (decoded != FramesPerCall) {
        return E_FAIL;
    }
    *decodedFramesPerChannel = static_cast<UINT32>(decoded);
    return S_OK;
}

extern "C" void DestroyOpusDecoder(OpusDecoderHandle handle) {
    if (!handle) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(handle->gate);
        opus_decoder_destroy(handle->decoder);
        handle->decoder = nullptr;
    }
    liveDecoderHandles.fetch_sub(1, std::memory_order_relaxed);
    delete handle;
}

UINT32 GetOpusLiveHandleCountForTests() {
    return liveEncoderHandles.load(std::memory_order_relaxed) +
        liveDecoderHandles.load(std::memory_order_relaxed);
}
