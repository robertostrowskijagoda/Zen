#ifndef RUNNER_ZEN_FILM_CODEC_H_
#define RUNNER_ZEN_FILM_CODEC_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// What the Linux film bridges (zen_video_bridge.cc) share: Zen's own H.264
// encoder (OpenH264, built from source with the app, so compressing works
// on every Linux), an MP4 writer of Zen's own (H.264 + AAC, index in front:
// it plays while it downloads) and a reader of ADTS AAC (what ffmpeg hands
// over through a pipe).
namespace zen_film {

// One coded frame: for video an access unit with 4-byte NAL lengths (no
// parameter sets), for audio one raw AAC frame.
struct Sample {
  std::vector<uint8_t> data;
  int64_t pts_us = 0;
  bool key = false;
};

struct VideoTrack {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> sps;
  std::vector<uint8_t> pps;
  std::vector<Sample> samples;
};

struct AudioTrack {
  // The AudioSpecificConfig (2 bytes for AAC-LC).
  std::vector<uint8_t> config;
  int sample_rate = 0;
  int channels = 0;
  std::vector<Sample> samples;
};

// The encoder: I420 frames in, coded frames into a VideoTrack.
class H264Encoder {
 public:
  H264Encoder();
  ~H264Encoder();
  H264Encoder(const H264Encoder&) = delete;
  H264Encoder& operator=(const H264Encoder&) = delete;

  // [width] and [height] must be even. False when OpenH264 refuses.
  bool Open(int width, int height, double fps, int bitrate);

  // One frame (planes and their strides); [pts_us] from the film's start.
  bool Encode(const uint8_t* y, int stride_y, const uint8_t* u, int stride_u,
              const uint8_t* v, int stride_v, int64_t pts_us);

  VideoTrack& track() { return track_; }

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  VideoTrack track_;
};

// Splits an ADTS stream into raw AAC frames; [pts_us] of each frame is
// counted from the first. False when it is not ADTS.
bool ReadAdts(const std::vector<uint8_t>& stream, AudioTrack* out);

// Writes [video] and, when it has samples, [audio] into an MP4 at [path]:
// `ftyp`, `moov` (before the frames), `mdat` with both tracks interleaved
// by time. [rotation] (0, 90, 180, 270) goes into the picture's matrix.
bool WriteMp4(const std::string& path, const VideoTrack& video,
              const AudioTrack* audio, int rotation, std::string* error);

}  // namespace zen_film

#endif  // RUNNER_ZEN_FILM_CODEC_H_
