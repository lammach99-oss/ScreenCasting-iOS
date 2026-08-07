#pragma once

#include <cstdint>

using BYTE = std::uint8_t;
using UINT32 = std::uint32_t;
using HRESULT = std::int32_t;
#define REALTIME_API __attribute__((visibility("default")))
#ifndef S_OK
#define S_OK ((HRESULT)0)
#define E_FAIL ((HRESULT)0x80004005L)
#define E_INVALIDARG ((HRESULT)0x80070057L)
#define E_OUTOFMEMORY ((HRESULT)0x8007000EL)
#define E_HANDLE ((HRESULT)0x80070006L)
#endif

constexpr HRESULT REALTIME_E_SRTP_AUTH = static_cast<HRESULT>(0x8004A001L);
constexpr HRESULT REALTIME_E_SRTP_REPLAY = static_cast<HRESULT>(0x8004A002L);
constexpr HRESULT REALTIME_E_SRTP_SSRC = static_cast<HRESULT>(0x8004A003L);
constexpr HRESULT REALTIME_E_BUFFER_TOO_SMALL = static_cast<HRESULT>(0x8004A004L);
