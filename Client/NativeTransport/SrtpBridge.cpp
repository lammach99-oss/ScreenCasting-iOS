#include "SrtpBridge.h"

#if __has_include(<srtp2/srtp.h>)
#include <srtp2/srtp.h>
#else
#include <srtp.h>
#endif

#include <array>
#include <atomic>
#include <climits>
#include <cstring>
#include <mutex>
#include <new>

namespace {
constexpr UINT32 KeyBytes = 16;
constexpr UINT32 SaltBytes = 12;
constexpr UINT32 MasterBytes = KeyBytes + SaltBytes;
constexpr UINT32 RtpHeaderBytes = 12;
constexpr UINT32 RtcpHeaderBytes = 8;
constexpr UINT32 GcmTagBytes = 16;
constexpr UINT32 SrtcpTrailerBytes = 4 + GcmTagBytes;

std::once_flag initOnce;
std::atomic<srtp_err_status_t> initStatus{srtp_err_status_fail};
std::atomic<UINT32> liveHandles{0};

void SecureErase(void* pointer, size_t size) {
    volatile BYTE* bytes = static_cast<volatile BYTE*>(pointer);
    while (size--) {
        *bytes++ = 0;
    }
}

UINT32 ReadNetwork32(const BYTE* bytes) {
    return (static_cast<UINT32>(bytes[0]) << 24) |
        (static_cast<UINT32>(bytes[1]) << 16) |
        (static_cast<UINT32>(bytes[2]) << 8) |
        static_cast<UINT32>(bytes[3]);
}

HRESULT MapStatus(srtp_err_status_t status) {
    switch (status) {
    case srtp_err_status_ok:
        return S_OK;
    case srtp_err_status_bad_param:
        return E_INVALIDARG;
    case srtp_err_status_alloc_fail:
        return E_OUTOFMEMORY;
    case srtp_err_status_auth_fail:
        return REALTIME_E_SRTP_AUTH;
    case srtp_err_status_replay_fail:
    case srtp_err_status_replay_old:
        return REALTIME_E_SRTP_REPLAY;
    default:
        return E_FAIL;
    }
}
} // namespace

struct SrtpContext {
    srtp_t session = nullptr;
    UINT32 ssrc = 0;
    bool sender = false;
    std::array<BYTE, MasterBytes> keyMaterial{};
    std::mutex gate;
};

namespace {
HRESULT Create(
    const BYTE* key, UINT32 keyLength, const BYTE* salt, UINT32 saltLength,
    UINT32 ssrc, bool sender, SrtpHandle* output) {
    if (!output) {
        return E_INVALIDARG;
    }
    *output = nullptr;
    if (!key || keyLength != KeyBytes || !salt || saltLength != SaltBytes) {
        return E_INVALIDARG;
    }

    std::call_once(initOnce, [] { initStatus.store(srtp_init()); });
    HRESULT result = MapStatus(initStatus.load());
    if (result != S_OK) {
        return result;
    }

    SrtpContext* context = new (std::nothrow) SrtpContext();
    if (!context) {
        return E_OUTOFMEMORY;
    }
    context->ssrc = ssrc;
    context->sender = sender;
    std::memcpy(context->keyMaterial.data(), key, KeyBytes);
    std::memcpy(context->keyMaterial.data() + KeyBytes, salt, SaltBytes);

    srtp_policy_t policy{};
    srtp_crypto_policy_set_aes_gcm_128_16_auth(&policy.rtp);
    srtp_crypto_policy_set_aes_gcm_128_16_auth(&policy.rtcp);
    policy.ssrc.type = ssrc_specific;
    policy.ssrc.value = ssrc;
    policy.key = context->keyMaterial.data();
    policy.window_size = 128;
    policy.allow_repeat_tx = 0;

    const srtp_err_status_t status = srtp_create(&context->session, &policy);
    SecureErase(context->keyMaterial.data(), context->keyMaterial.size());
    result = MapStatus(status);
    if (result != S_OK) {
        delete context;
        return result;
    }
    *output = context;
    liveHandles.fetch_add(1, std::memory_order_relaxed);
    return S_OK;
}

HRESULT ValidatePacket(
    SrtpHandle handle, BYTE* packet, UINT32 length, UINT32 minimum,
    UINT32 ssrcOffset) {
    if (!handle) {
        return E_HANDLE;
    }
    if (!packet || length < minimum || length > INT_MAX) {
        return E_INVALIDARG;
    }
    if (ReadNetwork32(packet + ssrcOffset) != handle->ssrc) {
        return REALTIME_E_SRTP_SSRC;
    }
    return S_OK;
}
} // namespace

extern "C" HRESULT CreateSrtpSender(
    const BYTE* key, UINT32 keyLength, const BYTE* salt, UINT32 saltLength,
    UINT32 ssrc, SrtpHandle* handle) {
    return Create(key, keyLength, salt, saltLength, ssrc, true, handle);
}

extern "C" HRESULT CreateSrtpReceiver(
    const BYTE* key, UINT32 keyLength, const BYTE* salt, UINT32 saltLength,
    UINT32 ssrc, SrtpHandle* handle) {
    return Create(key, keyLength, salt, saltLength, ssrc, false, handle);
}

extern "C" HRESULT ProtectRtp(
    SrtpHandle handle, BYTE* packet, UINT32 capacity, UINT32* length) {
    if (!length) {
        return E_INVALIDARG;
    }
    HRESULT result = ValidatePacket(handle, packet, *length, RtpHeaderBytes, 8);
    if (result != S_OK) {
        return result;
    }
    if (!handle->sender || capacity < *length || capacity - *length < GcmTagBytes) {
        return !handle->sender ? E_HANDLE : REALTIME_E_BUFFER_TOO_SMALL;
    }
    int nativeLength = static_cast<int>(*length);
    std::lock_guard<std::mutex> lock(handle->gate);
    result = MapStatus(srtp_protect(handle->session, packet, &nativeLength));
    if (result == S_OK) {
        *length = static_cast<UINT32>(nativeLength);
    }
    return result;
}

extern "C" HRESULT UnprotectRtp(
    SrtpHandle handle, BYTE* packet, UINT32* length) {
    if (!length) {
        return E_INVALIDARG;
    }
    HRESULT result = ValidatePacket(handle, packet, *length, RtpHeaderBytes + GcmTagBytes, 8);
    if (result != S_OK) {
        return result;
    }
    if (handle->sender) {
        return E_HANDLE;
    }
    int nativeLength = static_cast<int>(*length);
    std::lock_guard<std::mutex> lock(handle->gate);
    result = MapStatus(srtp_unprotect(handle->session, packet, &nativeLength));
    if (result == S_OK) {
        *length = static_cast<UINT32>(nativeLength);
    }
    return result;
}

extern "C" HRESULT ProtectRtcp(
    SrtpHandle handle, BYTE* packet, UINT32 capacity, UINT32* length) {
    if (!length) {
        return E_INVALIDARG;
    }
    HRESULT result = ValidatePacket(handle, packet, *length, RtcpHeaderBytes, 4);
    if (result != S_OK) {
        return result;
    }
    if (!handle->sender || capacity < *length || capacity - *length < SrtcpTrailerBytes) {
        return !handle->sender ? E_HANDLE : REALTIME_E_BUFFER_TOO_SMALL;
    }
    int nativeLength = static_cast<int>(*length);
    std::lock_guard<std::mutex> lock(handle->gate);
    result = MapStatus(srtp_protect_rtcp(handle->session, packet, &nativeLength));
    if (result == S_OK) {
        *length = static_cast<UINT32>(nativeLength);
    }
    return result;
}

extern "C" HRESULT UnprotectRtcp(
    SrtpHandle handle, BYTE* packet, UINT32* length) {
    if (!length) {
        return E_INVALIDARG;
    }
    HRESULT result = ValidatePacket(
        handle, packet, *length, RtcpHeaderBytes + SrtcpTrailerBytes, 4);
    if (result != S_OK) {
        return result;
    }
    if (handle->sender) {
        return E_HANDLE;
    }
    int nativeLength = static_cast<int>(*length);
    std::lock_guard<std::mutex> lock(handle->gate);
    result = MapStatus(srtp_unprotect_rtcp(handle->session, packet, &nativeLength));
    if (result == S_OK) {
        *length = static_cast<UINT32>(nativeLength);
    }
    return result;
}

extern "C" void DestroySrtp(SrtpHandle handle) {
    if (!handle) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(handle->gate);
        SecureErase(handle->keyMaterial.data(), handle->keyMaterial.size());
        if (handle->session) {
            srtp_dealloc(handle->session);
            handle->session = nullptr;
        }
    }
    liveHandles.fetch_sub(1, std::memory_order_relaxed);
    delete handle;
}

UINT32 GetSrtpLiveHandleCountForTests() {
    return liveHandles.load(std::memory_order_relaxed);
}
