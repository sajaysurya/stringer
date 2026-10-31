#ifndef STRINGER_AEC_H
#define STRINGER_AEC_H

#ifdef __cplusplus
extern "C" {
#endif

/// WebRTC AEC3 on one mono capture stream, with one mono render (reference)
/// stream. Noise suppression and gain control stay off: recognisers prefer
/// the signal as captured.
typedef struct stringer_aec stringer_aec;

/// Returns NULL if the sample rate is unsupported (use 16000).
stringer_aec *stringer_aec_create(int sample_rate);

/// Samples per frame (10 ms): 160 at 16 kHz.
int stringer_aec_frame_size(const stringer_aec *aec);

/// Processes one frame. `render` is what the speakers were sent (the system
/// track); `capture` is the microphone, cancelled in place. Both hold
/// `stringer_aec_frame_size` floats in [-1, 1]. Returns 0 on success.
int stringer_aec_process(stringer_aec *aec, const float *render, float *capture);

void stringer_aec_destroy(stringer_aec *aec);

#ifdef __cplusplus
}
#endif

#endif
