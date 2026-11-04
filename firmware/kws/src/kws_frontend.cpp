// SoC-callable TFLM micro_speech frontend based on the pinned K2 signal port.
// Input frames are assembled by the caller at 480 samples with a 320-sample hop.
#include "kws_frontend.h"

#include <stddef.h>
#include <stdint.h>

#include "kws_frontend_params.h"
#include "signal/src/complex.h"
#include "signal/src/energy.h"
#include "signal/src/fft_auto_scale.h"
#include "signal/src/filter_bank.h"
#include "signal/src/filter_bank_log.h"
#include "signal/src/filter_bank_spectral_subtraction.h"
#include "signal/src/filter_bank_square_root.h"
#include "signal/src/pcan_argc_fixed.h"
#include "signal/src/rfft.h"
#include "signal/src/window.h"

namespace {
constexpr int kFrame = KWS_FRONTEND_FRAME_SAMPLES;
constexpr int kNumChannels = KWS_FRONTEND_CHANNELS;
constexpr int kFftLength = 512;
constexpr int kEnergyBins = 257;

struct Params {
  const int16_t* window;
  const int16_t* ch_freq_starts;
  const int16_t* ch_weight_starts;
  const int16_t* ch_widths;
  const int16_t* weights;
  const int16_t* unweights;
  const int16_t* gain_lut;
  int32_t tail_mul, tail_add, tail_div, tail_sub, clip_min, clip_max;
  int32_t window_shift, fft_length, energy_start, energy_end, num_channels;
  int32_t snr_shift, log_out_scale, log_correction_bits;
  int32_t ss[8];
};

Params g_params{};
bool g_initialized = false;
int16_t g_window_params[480];
int16_t g_freq_start_params[41];
int16_t g_weight_start_params[41];
int16_t g_width_params[41];
int16_t g_weight_params[316];
int16_t g_unweight_params[316];
int16_t g_gain_lut_params[125];
int16_t g_windowed[kFrame];
int16_t g_scaled[kFrame];
int16_t g_work[kFftLength];
Complex<int16_t> g_spectrum[kFftLength / 2 + 1];
uint32_t g_energy[kEnergyBins];
uint64_t g_fb_acc[kNumChannels + 1];
uint32_t g_fb_sqrt[kNumChannels];
uint32_t g_ss_out[kNumChannels];
uint32_t g_noise_estimate[kNumChannels];
int16_t g_log_out[kNumChannels];
int8_t g_state_mem[4096];

uint32_t rd_u32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

int16_t rd_i16(uint32_t index) {
  const uint32_t offset = index * 2u;
  const uint16_t value = static_cast<uint16_t>(kws_frontend_params[offset]) |
                         (static_cast<uint16_t>(kws_frontend_params[offset + 1u]) << 8);
  return static_cast<int16_t>(value);
}

void load_i16_array(int16_t* dst, uint32_t count, uint32_t* cursor) {
  for (uint32_t i = 0; i < count; ++i)
    dst[i] = rd_i16((*cursor)++);
}

Params load_params() {
  Params p{};
  uint32_t o = 0;
  load_i16_array(g_window_params, 480, &o);
  load_i16_array(g_freq_start_params, 41, &o);
  load_i16_array(g_weight_start_params, 41, &o);
  load_i16_array(g_width_params, 41, &o);
  load_i16_array(g_weight_params, 316, &o);
  load_i16_array(g_unweight_params, 316, &o);
  load_i16_array(g_gain_lut_params, 125, &o);
  p.window = g_window_params;
  p.ch_freq_starts = g_freq_start_params;
  p.ch_weight_starts = g_weight_start_params;
  p.ch_widths = g_width_params;
  p.weights = g_weight_params;
  p.unweights = g_unweight_params;
  p.gain_lut = g_gain_lut_params;
  const uint8_t* s = kws_frontend_params + o * 2u;
  p.tail_mul = static_cast<int32_t>(rd_u32(s + 0));
  p.tail_add = static_cast<int32_t>(rd_u32(s + 4));
  p.tail_div = static_cast<int32_t>(rd_u32(s + 8));
  p.tail_sub = static_cast<int32_t>(rd_u32(s + 12));
  p.clip_min = static_cast<int32_t>(rd_u32(s + 16));
  p.clip_max = static_cast<int32_t>(rd_u32(s + 20));
  p.window_shift = static_cast<int32_t>(rd_u32(s + 24));
  p.fft_length = static_cast<int32_t>(rd_u32(s + 28));
  p.energy_start = static_cast<int32_t>(rd_u32(s + 32));
  p.energy_end = static_cast<int32_t>(rd_u32(s + 36));
  p.num_channels = static_cast<int32_t>(rd_u32(s + 40));
  p.snr_shift = static_cast<int32_t>(rd_u32(s + 44));
  p.log_out_scale = static_cast<int32_t>(rd_u32(s + 48));
  p.log_correction_bits = static_cast<int32_t>(rd_u32(s + 52));
  for (int i = 0; i < 8; ++i)
    p.ss[i] = static_cast<int32_t>(rd_u32(s + 56 + 4 * i));
  return p;
}
}  // namespace

extern "C" int kws_frontend_init(void) {
  g_params = load_params();
  if (g_params.num_channels != kNumChannels || g_params.fft_length != kFftLength ||
      g_params.tail_div == 0 ||
      tflm_signal::RfftInt16GetNeededMemory(kFftLength) > sizeof(g_state_mem)) {
    g_initialized = false;
    return -1;
  }

  const size_t state_size = tflm_signal::RfftInt16GetNeededMemory(kFftLength);
  tflm_signal::RfftInt16Init(kFftLength, g_state_mem, state_size);
  for (int i = 0; i < kNumChannels; ++i)
    g_noise_estimate[i] = 0;
  g_initialized = true;
  return 0;
}

extern "C" int kws_frontend_process_frame(const int16_t pcm[kFrame],
                                           int8_t feature[kNumChannels]) {
  if (!g_initialized || pcm == nullptr || feature == nullptr)
    return -1;

  tflite::tflm_signal::FilterbankConfig fb{};
  fb.num_channels = g_params.num_channels;
  fb.channel_frequency_starts = g_params.ch_freq_starts;
  fb.channel_weight_starts = g_params.ch_weight_starts;
  fb.channel_widths = g_params.ch_widths;
  fb.weights = g_params.weights;
  fb.unweights = g_params.unweights;

  tflite::tflm_signal::SpectralSubtractionConfig ss{};
  ss.smoothing = static_cast<uint32_t>(g_params.ss[0]);
  ss.one_minus_smoothing = static_cast<uint32_t>(g_params.ss[1]);
  ss.alternate_smoothing = static_cast<uint32_t>(g_params.ss[2]);
  ss.alternate_one_minus_smoothing = static_cast<uint32_t>(g_params.ss[3]);
  ss.smoothing_bits = g_params.ss[4];
  ss.spectral_subtraction_bits = g_params.ss[5];
  ss.min_signal_remaining = static_cast<uint32_t>(g_params.ss[6]);
  ss.clamping = g_params.ss[7] != 0;
  ss.num_channels = g_params.num_channels;

  tflm_signal::ApplyWindow(pcm, g_params.window, kFrame, g_params.window_shift, g_windowed);
  const int scale_bits = tflite::tflm_signal::FftAutoScale(g_windowed, kFrame, g_scaled);
  for (int i = 0; i < kFrame; ++i)
    g_work[i] = g_scaled[i];
  for (int i = kFrame; i < kFftLength; ++i)
    g_work[i] = 0;
  tflm_signal::RfftInt16Apply(g_state_mem, g_work, g_spectrum);
  for (int i = 0; i < kEnergyBins; ++i)
    g_energy[i] = 0;
  tflite::tflm_signal::SpectrumToEnergy(g_spectrum, g_params.energy_start,
                                        g_params.energy_end, g_energy);
  tflite::tflm_signal::FilterbankAccumulateChannels(&fb, g_energy, g_fb_acc);

  // FilterBankEval uses work_area[0] as scratch and copies channels from +1.
  tflite::tflm_signal::FilterbankSqrt(g_fb_acc + 1, g_params.num_channels,
                                      scale_bits, g_fb_sqrt);
  tflite::tflm_signal::FilterbankSpectralSubtraction(&ss, g_fb_sqrt, g_ss_out,
                                                     g_noise_estimate);
  for (int i = 0; i < kNumChannels; ++i)
    g_fb_sqrt[i] = g_ss_out[i];
  tflite::tflm_signal::ApplyPcanAutoGainControlFixed(
      g_params.gain_lut, g_params.snr_shift, g_noise_estimate, g_fb_sqrt,
      g_params.num_channels);
  tflite::tflm_signal::FilterbankLog(
      g_fb_sqrt, g_params.num_channels, g_params.log_out_scale,
      static_cast<uint32_t>(g_params.log_correction_bits), g_log_out);

  for (int i = 0; i < kNumChannels; ++i) {
    int32_t v = static_cast<int32_t>(g_log_out[i]) * g_params.tail_mul;
    v += g_params.tail_add;
    v /= g_params.tail_div;
    v += g_params.tail_sub;
    if (v > g_params.clip_max) v = g_params.clip_max;
    if (v < g_params.clip_min) v = g_params.clip_min;
    feature[i] = static_cast<int8_t>(v);
  }
  return 0;
}

extern "C" void kws_frontend_reset(void) {
  (void)kws_frontend_init();
}
