#include "stringer_aec.h"

#include <memory>
#include <vector>

#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

struct stringer_aec {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig config;
  int frame_size;
  std::vector<float> scratch;
};

extern "C" stringer_aec *stringer_aec_create(int sample_rate) {
  if (sample_rate != 16000 && sample_rate != 32000 && sample_rate != 48000) {
    return nullptr;
  }
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = false;
  config.noise_suppression.enabled = false;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  config.high_pass_filter.enabled = false;

  auto apm = webrtc::AudioProcessingBuilder().SetConfig(config).Create();
  if (!apm) {
    return nullptr;
  }
  auto *aec = new stringer_aec();
  aec->apm = apm;
  aec->config = webrtc::StreamConfig(sample_rate, 1);
  aec->frame_size = static_cast<int>(aec->config.num_frames());
  aec->scratch.resize(aec->frame_size);
  return aec;
}

extern "C" int stringer_aec_frame_size(const stringer_aec *aec) {
  return aec ? aec->frame_size : 0;
}

extern "C" int stringer_aec_process(stringer_aec *aec, const float *render, float *capture) {
  if (!aec) {
    return -1;
  }
  // The render path may modify its input, so feed it a copy.
  std::copy(render, render + aec->frame_size, aec->scratch.begin());
  float *render_channels[1] = {aec->scratch.data()};
  int err = aec->apm->ProcessReverseStream(render_channels, aec->config, aec->config, render_channels);
  if (err != 0) {
    return err;
  }
  // Both tracks share one timeline; AEC3 estimates the acoustic delay itself.
  aec->apm->set_stream_delay_ms(0);
  float *capture_channels[1] = {capture};
  return aec->apm->ProcessStream(capture_channels, aec->config, aec->config, capture_channels);
}

extern "C" void stringer_aec_destroy(stringer_aec *aec) {
  delete aec;
}
