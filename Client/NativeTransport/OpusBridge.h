#pragma once

#include "RealtimeAbi.h"

struct OpusEncoderContext;
struct OpusDecoderContext;
using OpusEncoderHandle = OpusEncoderContext*;
using OpusDecoderHandle = OpusDecoderContext*;

extern "C" {
REALTIME_API HRESULT CreateOpusEncoder(OpusEncoderHandle* handle);
REALTIME_API HRESULT EncodeOpus(
    OpusEncoderHandle handle, const std::int16_t* pcm, UINT32 framesPerChannel,
    BYTE* packet, UINT32 capacity, UINT32* length);
REALTIME_API void DestroyOpusEncoder(OpusEncoderHandle handle);
REALTIME_API HRESULT CreateOpusDecoder(OpusDecoderHandle* handle);
REALTIME_API HRESULT DecodeOpus(
    OpusDecoderHandle handle, const BYTE* packet, UINT32 length,
    std::int16_t* pcm, UINT32 capacityFramesPerChannel,
    UINT32* decodedFramesPerChannel);
REALTIME_API void DestroyOpusDecoder(OpusDecoderHandle handle);
}
