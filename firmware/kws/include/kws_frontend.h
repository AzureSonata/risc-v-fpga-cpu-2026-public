/* TFLM micro_speech audio frontend, adapted for frame-at-a-time SoC firmware. */
#ifndef KWS_FRONTEND_H
#define KWS_FRONTEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KWS_FRONTEND_FRAME_SAMPLES 480u
#define KWS_FRONTEND_HOP_SAMPLES 320u
#define KWS_FRONTEND_CHANNELS 40u
#define KWS_FRONTEND_WINDOW_ROWS 49u
#define KWS_FRONTEND_WINDOW_BYTES (KWS_FRONTEND_WINDOW_ROWS * KWS_FRONTEND_CHANNELS)

/* Initialize FFT work state and reset the stateful spectral-subtraction noise estimate. */
int kws_frontend_init(void);

/* Process one complete 480-sample signed PCM16 frame into one 40-byte int8 feature row. */
int kws_frontend_process_frame(const int16_t pcm[KWS_FRONTEND_FRAME_SAMPLES],
                              int8_t feature[KWS_FRONTEND_CHANNELS]);

/* Reset persistent frontend state after an audio discontinuity or FIFO overrun. */
void kws_frontend_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* KWS_FRONTEND_H */
