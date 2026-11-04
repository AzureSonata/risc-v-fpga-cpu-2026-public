#include "kws_frontend.h"

#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

static bool read_file(const char* path, std::vector<uint8_t>* out) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return false;
  out->assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
  return file.good() || file.eof();
}

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: test_frontend_host pcm.s16le expected_features.bin\n");
    return 2;
  }
  std::vector<uint8_t> pcm_bytes, expected;
  if (!read_file(argv[1], &pcm_bytes) || !read_file(argv[2], &expected)) {
    std::fprintf(stderr, "FAIL: cannot read fixture inputs\n");
    return 2;
  }
  if ((pcm_bytes.size() & 1u) != 0u || pcm_bytes.size() / 2u < KWS_FRONTEND_FRAME_SAMPLES) {
    std::fprintf(stderr, "FAIL: PCM must contain at least one complete S16 sample frame\n");
    return 2;
  }
  const size_t sample_count = pcm_bytes.size() / 2u;
  const size_t frames = 1u + (sample_count - KWS_FRONTEND_FRAME_SAMPLES) /
                               KWS_FRONTEND_HOP_SAMPLES;
  if (expected.size() != frames * KWS_FRONTEND_CHANNELS) {
    std::fprintf(stderr, "FAIL: expected feature size %zu, got %zu\n",
                 frames * KWS_FRONTEND_CHANNELS, expected.size());
    return 2;
  }
  if (kws_frontend_init() != 0) {
    std::fprintf(stderr, "FAIL: frontend init\n");
    return 2;
  }
  if (kws_frontend_process_frame(nullptr, nullptr) >= 0) {
    std::fprintf(stderr, "FAIL: frontend accepted null buffers\n");
    return 1;
  }

  int16_t frame[KWS_FRONTEND_FRAME_SAMPLES];
  int8_t feature[KWS_FRONTEND_CHANNELS];
  for (size_t f = 0; f < frames; ++f) {
    for (size_t i = 0; i < KWS_FRONTEND_FRAME_SAMPLES; ++i) {
      const size_t p = (f * KWS_FRONTEND_HOP_SAMPLES + i) * 2u;
      const uint16_t raw = static_cast<uint16_t>(pcm_bytes[p]) |
                           (static_cast<uint16_t>(pcm_bytes[p + 1u]) << 8);
      frame[i] = static_cast<int16_t>(raw);
    }
    if (kws_frontend_process_frame(frame, feature) != 0) {
      std::fprintf(stderr, "FAIL: frontend rejected frame %zu\n", f);
      return 1;
    }
    for (size_t c = 0; c < KWS_FRONTEND_CHANNELS; ++c) {
      const uint8_t actual = static_cast<uint8_t>(feature[c]);
      const uint8_t want = expected[f * KWS_FRONTEND_CHANNELS + c];
      if (actual != want) {
        std::fprintf(stderr, "FAIL: frame=%zu channel=%zu got=%d expected=%d\n",
                     f, c, static_cast<int8_t>(actual), static_cast<int8_t>(want));
        return 1;
      }
    }
  }
  kws_frontend_reset();
  for (size_t i = 0; i < KWS_FRONTEND_FRAME_SAMPLES; ++i) {
    const uint16_t raw = static_cast<uint16_t>(pcm_bytes[i * 2u]) |
                         (static_cast<uint16_t>(pcm_bytes[i * 2u + 1u]) << 8);
    frame[i] = static_cast<int16_t>(raw);
  }
  if (kws_frontend_process_frame(frame, feature) != 0) {
    std::fprintf(stderr, "FAIL: frontend reset did not reinitialize\n");
    return 1;
  }
  for (size_t c = 0; c < KWS_FRONTEND_CHANNELS; ++c) {
    if (static_cast<uint8_t>(feature[c]) != expected[c]) {
      std::fprintf(stderr, "FAIL: reset replay mismatch at channel=%zu\n", c);
      return 1;
    }
  }
  std::printf("PASS: %zu frames, %zu feature bytes exact\n",
              frames, expected.size());
  return 0;
}
