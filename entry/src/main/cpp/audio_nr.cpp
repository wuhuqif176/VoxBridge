#include "napi/native_api.h"
#include <hilog/log.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

#define HMIC_DF_LOG_TAG "HarmonyMicDF"
#define DF_LOG_INFO(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, 0xC0DE, HMIC_DF_LOG_TAG, fmt, ##__VA_ARGS__)
#define DF_LOG_ERROR(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, 0xC0DE, HMIC_DF_LOG_TAG, fmt, ##__VA_ARGS__)

// libDF (DeepFilterNet3) C API, see third_party/DeepFilterNet/libDF/src/capi.rs
struct DFState;
extern "C" {
DFState *df_create(const char *path, float attenLim);
size_t df_get_frame_length(DFState *st);
float df_process_frame(DFState *st, const float *input, float *output);
void df_set_atten_lim(DFState *st, float limDb);
void df_set_post_filter_beta(DFState *st, float beta);
void df_free(DFState *st);
}

namespace {
struct DfContext {
    DFState *df = nullptr;
    size_t hop = 0; // frame length in samples (DF3: 480 @ 48kHz)
    std::vector<float> inFifo;
    size_t inOffset = 0;
    std::vector<float> outFifo;
    size_t outOffset = 0;
    std::vector<float> frameIn;
    std::vector<float> frameOut;
    bool bypass = false;
    bool active = false;
    int pendingStrength = 0; // 0=standard 1=enhanced 2=extreme; applied on start, kept across restarts
    uint32_t frameCount = 0;
    double frameTotalMs = 0.0;
    double frameMaxMs = 0.0;
    std::recursive_mutex mutex;
};

DfContext g_ctx;
std::string g_lastError;

// strength tier -> post-filter beta (0 disables the post filter)
float StrengthToBeta(int tier)
{
    if (tier == 1) {
        return 0.03f;
    }
    if (tier == 2) {
        return 0.08f;
    }
    return 0.0f;
}

void DfSetError(const char *stage, const char *detail)
{
    char buffer[160];
    std::snprintf(buffer, sizeof(buffer), "%s: %s", stage, detail);
    g_lastError = buffer;
    DF_LOG_ERROR("df stage failed: %{public}s", buffer);
}

void DfConsumeIn(size_t count)
{
    g_ctx.inOffset += count;
    if (g_ctx.inOffset >= g_ctx.inFifo.size()) {
        g_ctx.inFifo.clear();
        g_ctx.inOffset = 0;
    }
}

void DfConsumeOut(size_t count)
{
    g_ctx.outOffset += count;
    if (g_ctx.outOffset >= g_ctx.outFifo.size()) {
        g_ctx.outFifo.clear();
        g_ctx.outOffset = 0;
    }
}

napi_value DfIsSupported(napi_env env, napi_callback_info info)
{
    (void)info;
    // Pure-software DeepFilterNet3 inference (embedded ONNX model), always available.
    napi_value value = nullptr;
    napi_get_boolean(env, true, &value);
    return value;
}

napi_value DfStart(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value resultValue = nullptr;
    napi_get_boolean(env, false, &resultValue);
    std::lock_guard<std::recursive_mutex> lock(g_ctx.mutex);
    if (g_ctx.active) {
        napi_get_boolean(env, true, &resultValue);
        return resultValue;
    }
    g_lastError.clear();
    // NULL path -> embedded DeepFilterNet3 model; atten_lim 100 dB = full strength.
    DFState *df = df_create(nullptr, 100.0f);
    if (df == nullptr) {
        DfSetError("df_create", "returned null");
        return resultValue;
    }
    g_ctx.df = df;
    g_ctx.hop = df_get_frame_length(df);
    if (g_ctx.hop == 0) {
        df_free(df);
        g_ctx.df = nullptr;
        DfSetError("df_get_frame_length", "returned 0");
        return resultValue;
    }
    g_ctx.frameIn.assign(g_ctx.hop, 0.0f);
    g_ctx.frameOut.assign(g_ctx.hop, 0.0f);
    g_ctx.inFifo.clear();
    g_ctx.inOffset = 0;
    g_ctx.outFifo.clear();
    g_ctx.outOffset = 0;
    g_ctx.frameCount = 0;
    g_ctx.frameTotalMs = 0.0;
    g_ctx.frameMaxMs = 0.0;
    df_set_post_filter_beta(df, StrengthToBeta(g_ctx.pendingStrength));
    g_ctx.active = true;
    DF_LOG_INFO("df started: 48kHz/mono/S16LE, hop=%{public}zu samples, strength=%{public}d", g_ctx.hop,
        g_ctx.pendingStrength);
    napi_get_boolean(env, true, &resultValue);
    return resultValue;
}

napi_value DfStop(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::recursive_mutex> lock(g_ctx.mutex);
    if (g_ctx.active) {
        if (g_ctx.df != nullptr) {
            df_free(g_ctx.df);
            g_ctx.df = nullptr;
        }
        g_ctx.active = false;
        g_ctx.inFifo.clear();
        g_ctx.inOffset = 0;
        g_ctx.outFifo.clear();
        g_ctx.outOffset = 0;
        DF_LOG_INFO("df stopped");
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value DfProcess(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void *chunkData = nullptr;
    size_t chunkSize = 0;
    bool isArrayBuffer = false;
    napi_is_arraybuffer(env, args[0], &isArrayBuffer);
    if (!isArrayBuffer || napi_get_arraybuffer_info(env, args[0], &chunkData, &chunkSize) != napi_ok) {
        napi_throw_error(env, "40000", "expected ArrayBuffer");
        return nullptr;
    }
    const size_t numSamples = chunkSize / 2; // S16LE mono
    std::vector<uint8_t> scratch(chunkSize, 0);
    {
        std::lock_guard<std::recursive_mutex> lock(g_ctx.mutex);
        if (!g_ctx.active || g_ctx.bypass || numSamples == 0) {
            // passthrough
            if (chunkSize > 0) {
                std::memcpy(scratch.data(), chunkData, chunkSize);
            }
        } else {
            // S16LE -> f32, append to input FIFO
            const int16_t *in = static_cast<const int16_t *>(chunkData);
            g_ctx.inFifo.reserve(g_ctx.inFifo.size() - g_ctx.inOffset + numSamples);
            for (size_t i = 0; i < numSamples; ++i) {
                g_ctx.inFifo.push_back(static_cast<float>(in[i]) / 32768.0f);
            }
            // process all complete frames
            while (g_ctx.inFifo.size() - g_ctx.inOffset >= g_ctx.hop) {
                std::memcpy(g_ctx.frameIn.data(), g_ctx.inFifo.data() + g_ctx.inOffset,
                    g_ctx.hop * sizeof(float));
                DfConsumeIn(g_ctx.hop);
                const auto t0 = std::chrono::steady_clock::now();
                df_process_frame(g_ctx.df, g_ctx.frameIn.data(), g_ctx.frameOut.data());
                const double frameMs =
                    std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
                g_ctx.frameTotalMs += frameMs;
                if (frameMs > g_ctx.frameMaxMs) {
                    g_ctx.frameMaxMs = frameMs;
                }
                g_ctx.frameCount += 1;
                if (g_ctx.frameCount >= 100) {
                    DF_LOG_INFO("df frame timing: avg=%{public}.2fms max=%{public}.2fms (last 100 frames)",
                        g_ctx.frameTotalMs / static_cast<double>(g_ctx.frameCount), g_ctx.frameMaxMs);
                    g_ctx.frameCount = 0;
                    g_ctx.frameTotalMs = 0.0;
                    g_ctx.frameMaxMs = 0.0;
                }
                g_ctx.outFifo.insert(g_ctx.outFifo.end(), g_ctx.frameOut.begin(), g_ctx.frameOut.end());
            }
            // drain up to numSamples from output FIFO; tail zero-padded at stream start (DF lookahead)
            size_t available = g_ctx.outFifo.size() - g_ctx.outOffset;
            size_t take = std::min(available, numSamples);
            int16_t *out = reinterpret_cast<int16_t *>(scratch.data());
            for (size_t i = 0; i < take; ++i) {
                float s = g_ctx.outFifo[g_ctx.outOffset + i];
                s = std::max(-1.0f, std::min(1.0f, s));
                out[i] = static_cast<int16_t>(std::lrintf(s * 32767.0f));
            }
            DfConsumeOut(take);
        }
    }
    napi_value outBuffer = nullptr;
    void *outData = nullptr;
    if (chunkSize == 0) {
        if (napi_create_arraybuffer(env, 0, &outData, &outBuffer) == napi_ok) {
            return outBuffer;
        }
        napi_throw_error(env, "50000", "create arraybuffer failed");
        return nullptr;
    }
    if (napi_create_arraybuffer(env, chunkSize, &outData, &outBuffer) != napi_ok) {
        napi_throw_error(env, "50000", "create arraybuffer failed");
        return nullptr;
    }
    std::memcpy(outData, scratch.data(), chunkSize);
    return outBuffer;
}

napi_value DfGetLastError(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::recursive_mutex> lock(g_ctx.mutex);
    napi_value value = nullptr;
    napi_create_string_utf8(env, g_lastError.c_str(), NAPI_AUTO_LENGTH, &value);
    return value;
}

napi_value DfSetBypass(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool bypass = false;
    napi_get_value_bool(env, args[0], &bypass);
    std::lock_guard<std::recursive_mutex> lock(g_ctx.mutex);
    g_ctx.bypass = bypass;
    DF_LOG_INFO("df bypass set: %{public}d", static_cast<int>(bypass));
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value DfSetStrength(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t tier = 0;
    napi_get_value_int32(env, args[0], &tier);
    if (tier < 0) {
        tier = 0;
    }
    if (tier > 2) {
        tier = 2;
    }
    std::lock_guard<std::recursive_mutex> lock(g_ctx.mutex);
    g_ctx.pendingStrength = tier;
    if (g_ctx.active && g_ctx.df != nullptr) {
        df_set_post_filter_beta(g_ctx.df, StrengthToBeta(tier));
    }
    DF_LOG_INFO("df strength set: tier=%{public}d beta=%{public}f active=%{public}d", tier,
        StrengthToBeta(tier), static_cast<int>(g_ctx.active));
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"nrIsSupported", nullptr, DfIsSupported, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nrStart", nullptr, DfStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nrStop", nullptr, DfStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nrProcess", nullptr, DfProcess, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nrSetBypass", nullptr, DfSetBypass, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nrSetStrength", nullptr, DfSetStrength, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nrGetLastError", nullptr, DfGetLastError, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module audioNrModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "audio_nr",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterAudioNrModule(void)
{
    napi_module_register(&audioNrModule);
}
