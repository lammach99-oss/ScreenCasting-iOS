#pragma once

#include "RealtimeAbi.h"

struct SrtpContext;
using SrtpHandle = SrtpContext*;

extern "C" {
REALTIME_API HRESULT CreateSrtpSender(
    const BYTE* key, UINT32 keyLength, const BYTE* salt, UINT32 saltLength,
    UINT32 ssrc, SrtpHandle* handle);
REALTIME_API HRESULT CreateSrtpReceiver(
    const BYTE* key, UINT32 keyLength, const BYTE* salt, UINT32 saltLength,
    UINT32 ssrc, SrtpHandle* handle);
REALTIME_API HRESULT ProtectRtp(
    SrtpHandle handle, BYTE* packet, UINT32 capacity, UINT32* length);
REALTIME_API HRESULT UnprotectRtp(
    SrtpHandle handle, BYTE* packet, UINT32* length);
REALTIME_API HRESULT ProtectRtcp(
    SrtpHandle handle, BYTE* packet, UINT32 capacity, UINT32* length);
REALTIME_API HRESULT UnprotectRtcp(
    SrtpHandle handle, BYTE* packet, UINT32* length);
REALTIME_API void DestroySrtp(SrtpHandle handle);
}
