#include "zen_film_codec.h"

#include <wels/codec_api.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <utility>

namespace zen_film {

// ---------------------------------------------------------------------------
// H.264 (OpenH264).

struct H264Encoder::Impl {
  ISVCEncoder* encoder = nullptr;
  int width = 0;
  int height = 0;

  ~Impl() {
    if (encoder != nullptr) {
      encoder->Uninitialize();
      WelsDestroySVCEncoder(encoder);
    }
  }
};

H264Encoder::H264Encoder() : impl_(new Impl()) {}

H264Encoder::~H264Encoder() = default;

bool H264Encoder::Open(int width, int height, double fps, int bitrate) {
  if (width <= 0 || height <= 0 || (width % 2) != 0 || (height % 2) != 0) {
    return false;
  }
  if (WelsCreateSVCEncoder(&impl_->encoder) != 0 ||
      impl_->encoder == nullptr) {
    impl_->encoder = nullptr;
    return false;
  }
  const float rate = static_cast<float>(fps > 1 && fps < 121 ? fps : 30);
  SEncParamExt param;
  memset(&param, 0, sizeof(param));
  impl_->encoder->GetDefaultParams(&param);
  param.iUsageType = CAMERA_VIDEO_REAL_TIME;
  param.iPicWidth = width;
  param.iPicHeight = height;
  param.iTargetBitrate = bitrate;
  param.iMaxBitrate = bitrate + bitrate / 4;
  param.iRCMode = RC_BITRATE_MODE;
  param.fMaxFrameRate = rate;
  param.bEnableFrameSkip = false;
  param.uiIntraPeriod = static_cast<unsigned int>(rate * 2);
  param.iSpatialLayerNum = 1;
  param.iTemporalLayerNum = 1;
  param.iMultipleThreadIdc = 0;  // as many as the computer has
  param.sSpatialLayers[0].iVideoWidth = width;
  param.sSpatialLayers[0].iVideoHeight = height;
  param.sSpatialLayers[0].fFrameRate = rate;
  param.sSpatialLayers[0].iSpatialBitrate = bitrate;
  param.sSpatialLayers[0].iMaxSpatialBitrate = bitrate + bitrate / 4;
  param.sSpatialLayers[0].sSliceArgument.uiSliceMode = SM_SINGLE_SLICE;
  if (impl_->encoder->InitializeExt(&param) != 0) {
    return false;
  }
  int format = videoFormatI420;
  impl_->encoder->SetOption(ENCODER_OPTION_DATAFORMAT, &format);
  impl_->width = width;
  impl_->height = height;
  track_.width = width;
  track_.height = height;
  return true;
}

namespace {

// Calls [each] with every NAL unit (without its start code) of the
// Annex B stream [data].
template <typename F>
void ForEachNal(const uint8_t* data, size_t size, F each) {
  size_t i = 0;
  auto start_code = [&](size_t at, size_t* length) {
    if (at + 3 <= size && data[at] == 0 && data[at + 1] == 0) {
      if (data[at + 2] == 1) {
        *length = 3;
        return true;
      }
      if (at + 4 <= size && data[at + 2] == 0 && data[at + 3] == 1) {
        *length = 4;
        return true;
      }
    }
    return false;
  };
  size_t length = 0;
  while (i < size && !start_code(i, &length)) {
    i++;
  }
  while (i < size) {
    const size_t begin = i + length;
    size_t end = begin;
    size_t next_length = 0;
    while (end < size && !start_code(end, &next_length)) {
      end++;
    }
    if (end > begin) {
      each(data + begin, end - begin);
    }
    i = end;
    length = next_length;
  }
}

}  // namespace

bool H264Encoder::Encode(const uint8_t* y, int stride_y, const uint8_t* u,
                         int stride_u, const uint8_t* v, int stride_v,
                         int64_t pts_us) {
  if (impl_->encoder == nullptr) {
    return false;
  }
  SSourcePicture picture;
  memset(&picture, 0, sizeof(picture));
  picture.iColorFormat = videoFormatI420;
  picture.iPicWidth = impl_->width;
  picture.iPicHeight = impl_->height;
  picture.iStride[0] = stride_y;
  picture.iStride[1] = stride_u;
  picture.iStride[2] = stride_v;
  picture.pData[0] = const_cast<uint8_t*>(y);
  picture.pData[1] = const_cast<uint8_t*>(u);
  picture.pData[2] = const_cast<uint8_t*>(v);
  picture.uiTimeStamp = pts_us / 1000;
  SFrameBSInfo info;
  memset(&info, 0, sizeof(info));
  if (impl_->encoder->EncodeFrame(&picture, &info) != cmResultSuccess) {
    return false;
  }
  if (info.eFrameType == videoFrameTypeSkip ||
      info.eFrameType == videoFrameTypeInvalid) {
    return true;
  }
  Sample sample;
  sample.pts_us = pts_us;
  sample.key = info.eFrameType == videoFrameTypeIDR;
  for (int l = 0; l < info.iLayerNum; l++) {
    const SLayerBSInfo& layer = info.sLayerInfo[l];
    size_t bytes = 0;
    for (int n = 0; n < layer.iNalCount; n++) {
      bytes += static_cast<size_t>(layer.pNalLengthInByte[n]);
    }
    ForEachNal(layer.pBsBuf, bytes, [&](const uint8_t* nal, size_t length) {
      const int type = nal[0] & 0x1F;
      if (type == 7) {
        track_.sps.assign(nal, nal + length);
      } else if (type == 8) {
        track_.pps.assign(nal, nal + length);
      } else {
        const uint32_t n = static_cast<uint32_t>(length);
        const uint8_t prefix[4] = {static_cast<uint8_t>(n >> 24),
                                   static_cast<uint8_t>(n >> 16),
                                   static_cast<uint8_t>(n >> 8),
                                   static_cast<uint8_t>(n)};
        sample.data.insert(sample.data.end(), prefix, prefix + 4);
        sample.data.insert(sample.data.end(), nal, nal + length);
      }
    });
  }
  if (!sample.data.empty()) {
    track_.samples.push_back(std::move(sample));
  }
  return true;
}

// ---------------------------------------------------------------------------
// ADTS.

bool ReadAdts(const std::vector<uint8_t>& stream, AudioTrack* out) {
  static const int kRates[] = {96000, 88200, 64000, 48000, 44100, 32000,
                               24000, 22050, 16000, 12000, 11025, 8000, 7350};
  size_t at = 0;
  int64_t frames = 0;
  while (at + 7 <= stream.size()) {
    const uint8_t* h = stream.data() + at;
    if (h[0] != 0xFF || (h[1] & 0xF0) != 0xF0) {
      return !out->samples.empty();
    }
    const bool no_crc = (h[1] & 0x01) != 0;
    const int profile = (h[2] >> 6) & 0x03;
    const int rate_index = (h[2] >> 2) & 0x0F;
    const int channels = ((h[2] & 0x01) << 2) | ((h[3] >> 6) & 0x03);
    const size_t length = (static_cast<size_t>(h[3] & 0x03) << 11) |
                          (static_cast<size_t>(h[4]) << 3) |
                          (static_cast<size_t>(h[5]) >> 5);
    const size_t header = no_crc ? 7 : 9;
    if (rate_index > 12 || length < header || at + length > stream.size()) {
      return !out->samples.empty();
    }
    if (out->config.empty()) {
      const int object = profile + 1;
      out->config = {
          static_cast<uint8_t>((object << 3) | (rate_index >> 1)),
          static_cast<uint8_t>(((rate_index & 1) << 7) | (channels << 3))};
      out->sample_rate = kRates[rate_index];
      out->channels = channels;
    }
    Sample sample;
    sample.data.assign(h + header, h + length);
    sample.pts_us = frames * 1024 * 1000000 / out->sample_rate;
    sample.key = true;
    out->samples.push_back(std::move(sample));
    frames++;
    at += length;
  }
  return !out->samples.empty();
}

// ---------------------------------------------------------------------------
// MP4.

namespace {

class Box {
 public:
  explicit Box(const char* type) {
    U32(0);
    bytes_.insert(bytes_.end(), type, type + 4);
  }

  void U8(uint32_t v) { bytes_.push_back(static_cast<uint8_t>(v)); }
  void U16(uint32_t v) {
    U8(v >> 8);
    U8(v);
  }
  void U24(uint32_t v) {
    U8(v >> 16);
    U16(v);
  }
  void U32(uint32_t v) {
    U16(v >> 16);
    U16(v);
  }
  void Zeros(size_t n) { bytes_.insert(bytes_.end(), n, 0); }
  void Bytes(const std::vector<uint8_t>& b) {
    bytes_.insert(bytes_.end(), b.begin(), b.end());
  }
  void Text(const char* s, size_t n) { bytes_.insert(bytes_.end(), s, s + n); }
  void Add(const Box& child) { Bytes(child.Done()); }

  // The box with its size written in.
  std::vector<uint8_t> Done() const {
    std::vector<uint8_t> out = bytes_;
    const uint32_t size = static_cast<uint32_t>(out.size());
    out[0] = static_cast<uint8_t>(size >> 24);
    out[1] = static_cast<uint8_t>(size >> 16);
    out[2] = static_cast<uint8_t>(size >> 8);
    out[3] = static_cast<uint8_t>(size);
    return out;
  }

 private:
  std::vector<uint8_t> bytes_;
};

void Matrix(Box* b, int rotation, int width, int height) {
  const uint32_t one = 0x10000;
  const uint32_t minus = 0xFFFF0000u;
  const uint32_t w = 0x40000000u;
  uint32_t m[9] = {one, 0, 0, 0, one, 0, 0, 0, w};
  if (rotation == 90) {
    const uint32_t r[9] = {0, one, 0, minus, 0, 0,
                           static_cast<uint32_t>(height) << 16, 0, w};
    std::copy(r, r + 9, m);
  } else if (rotation == 180) {
    const uint32_t r[9] = {minus, 0, 0, 0, minus, 0,
                           static_cast<uint32_t>(width) << 16,
                           static_cast<uint32_t>(height) << 16, w};
    std::copy(r, r + 9, m);
  } else if (rotation == 270) {
    const uint32_t r[9] = {0, minus, 0, one, 0, 0,
                           0, static_cast<uint32_t>(width) << 16, w};
    std::copy(r, r + 9, m);
  }
  for (uint32_t v : m) {
    b->U32(v);
  }
}

// One track as the index describes it.
struct TrackIndex {
  uint32_t timescale = 0;
  std::vector<uint32_t> durations;
  std::vector<uint32_t> sizes;
  std::vector<uint32_t> offsets;
  std::vector<uint32_t> keys;  // 1-based; empty: every sample is a key
  uint64_t duration = 0;
};

TrackIndex IndexOf(const std::vector<Sample>& samples, uint32_t timescale,
                   bool all_keys) {
  TrackIndex t;
  t.timescale = timescale;
  const size_t n = samples.size();
  for (size_t i = 0; i < n; i++) {
    int64_t next = i + 1 < n ? samples[i + 1].pts_us : -1;
    int64_t delta = next >= 0 ? next - samples[i].pts_us : -1;
    if (delta <= 0) {
      // The last one (or a timestamp that did not move): as long as the
      // one before, else a 30th of a second.
      delta = i > 0 ? samples[i].pts_us - samples[i - 1].pts_us : 33333;
      if (delta <= 0) {
        delta = 33333;
      }
    }
    const uint32_t ticks = static_cast<uint32_t>(
        std::max<int64_t>(1, delta * timescale / 1000000));
    t.durations.push_back(ticks);
    t.sizes.push_back(static_cast<uint32_t>(samples[i].data.size()));
    t.duration += ticks;
    if (!all_keys && samples[i].key) {
      t.keys.push_back(static_cast<uint32_t>(i + 1));
    }
  }
  return t;
}

Box Stbl(const TrackIndex& t, const Box& stsd, bool all_keys) {
  Box stbl("stbl");
  stbl.Add(stsd);
  Box stts("stts");
  stts.U32(0);
  std::vector<std::pair<uint32_t, uint32_t>> runs;
  for (uint32_t d : t.durations) {
    if (!runs.empty() && runs.back().second == d) {
      runs.back().first++;
    } else {
      runs.emplace_back(1, d);
    }
  }
  stts.U32(static_cast<uint32_t>(runs.size()));
  for (const auto& r : runs) {
    stts.U32(r.first);
    stts.U32(r.second);
  }
  stbl.Add(stts);
  if (!all_keys) {
    Box stss("stss");
    stss.U32(0);
    stss.U32(static_cast<uint32_t>(t.keys.size()));
    for (uint32_t k : t.keys) {
      stss.U32(k);
    }
    stbl.Add(stss);
  }
  Box stsc("stsc");
  stsc.U32(0);
  stsc.U32(1);
  stsc.U32(1);  // from the first chunk on
  stsc.U32(1);  // one sample per chunk
  stsc.U32(1);
  stbl.Add(stsc);
  Box stsz("stsz");
  stsz.U32(0);
  stsz.U32(0);
  stsz.U32(static_cast<uint32_t>(t.sizes.size()));
  for (uint32_t s : t.sizes) {
    stsz.U32(s);
  }
  stbl.Add(stsz);
  Box stco("stco");
  stco.U32(0);
  stco.U32(static_cast<uint32_t>(t.offsets.size()));
  for (uint32_t o : t.offsets) {
    stco.U32(o);
  }
  stbl.Add(stco);
  return stbl;
}

Box Dinf() {
  Box dinf("dinf");
  Box dref("dref");
  dref.U32(0);
  dref.U32(1);
  Box url("url ");
  url.U32(1);  // the data is in this file
  dref.Add(url);
  dinf.Add(dref);
  return dinf;
}

Box Trak(uint32_t id, const TrackIndex& t, uint64_t movie_duration,
         const char* handler, const char* name, const Box& media_header,
         const Box& stsd, bool all_keys, int rotation, int width, int height,
         bool audio) {
  Box trak("trak");
  Box tkhd("tkhd");
  tkhd.U32(0x000003);  // enabled, in the movie
  tkhd.U32(0);
  tkhd.U32(0);
  tkhd.U32(id);
  tkhd.U32(0);
  tkhd.U32(static_cast<uint32_t>(movie_duration));
  tkhd.Zeros(8);
  tkhd.U16(0);
  tkhd.U16(0);
  tkhd.U16(audio ? 0x0100 : 0);
  tkhd.U16(0);
  Matrix(&tkhd, rotation, width, height);
  tkhd.U32(static_cast<uint32_t>(width) << 16);
  tkhd.U32(static_cast<uint32_t>(height) << 16);
  trak.Add(tkhd);
  Box mdia("mdia");
  Box mdhd("mdhd");
  mdhd.U32(0);
  mdhd.U32(0);
  mdhd.U32(0);
  mdhd.U32(t.timescale);
  mdhd.U32(static_cast<uint32_t>(t.duration));
  mdhd.U16(0x55C4);  // "und"
  mdhd.U16(0);
  mdia.Add(mdhd);
  Box hdlr("hdlr");
  hdlr.U32(0);
  hdlr.U32(0);
  hdlr.Text(handler, 4);
  hdlr.Zeros(12);
  hdlr.Text(name, strlen(name) + 1);
  mdia.Add(hdlr);
  Box minf("minf");
  minf.Add(media_header);
  minf.Add(Dinf());
  minf.Add(Stbl(t, stsd, all_keys));
  mdia.Add(minf);
  trak.Add(mdia);
  return trak;
}

Box VideoStsd(const VideoTrack& v) {
  Box stsd("stsd");
  stsd.U32(0);
  stsd.U32(1);
  Box avc1("avc1");
  avc1.Zeros(6);
  avc1.U16(1);  // data reference
  avc1.Zeros(16);
  avc1.U16(static_cast<uint32_t>(v.width));
  avc1.U16(static_cast<uint32_t>(v.height));
  avc1.U32(0x00480000);
  avc1.U32(0x00480000);
  avc1.U32(0);
  avc1.U16(1);
  avc1.Zeros(32);
  avc1.U16(0x0018);
  avc1.U16(0xFFFF);
  Box avcc("avcC");
  avcc.U8(1);
  avcc.U8(v.sps.size() > 1 ? v.sps[1] : 66);
  avcc.U8(v.sps.size() > 2 ? v.sps[2] : 0);
  avcc.U8(v.sps.size() > 3 ? v.sps[3] : 31);
  avcc.U8(0xFF);  // 4-byte NAL lengths
  avcc.U8(0xE1);  // one SPS
  avcc.U16(static_cast<uint32_t>(v.sps.size()));
  avcc.Bytes(v.sps);
  avcc.U8(1);  // one PPS
  avcc.U16(static_cast<uint32_t>(v.pps.size()));
  avcc.Bytes(v.pps);
  avc1.Add(avcc);
  stsd.Add(avc1);
  return stsd;
}

Box AudioStsd(const AudioTrack& a) {
  Box stsd("stsd");
  stsd.U32(0);
  stsd.U32(1);
  Box mp4a("mp4a");
  mp4a.Zeros(6);
  mp4a.U16(1);
  mp4a.Zeros(8);
  mp4a.U16(static_cast<uint32_t>(a.channels));
  mp4a.U16(16);
  mp4a.U16(0);
  mp4a.U16(0);
  mp4a.U32(static_cast<uint32_t>(a.sample_rate) << 16);
  Box esds("esds");
  esds.U32(0);
  const uint32_t dsi = static_cast<uint32_t>(a.config.size());
  esds.U8(0x03);  // ES descriptor
  esds.U8(3 + 2 + 13 + 2 + dsi + 3);
  esds.U16(0);  // ES id
  esds.U8(0);
  esds.U8(0x04);  // decoder config
  esds.U8(13 + 2 + dsi);
  esds.U8(0x40);  // MPEG-4 audio
  esds.U8(0x15);  // audio stream
  esds.U24(0);
  esds.U32(0);
  esds.U32(0);
  esds.U8(0x05);  // decoder specific info
  esds.U8(dsi);
  esds.Bytes(a.config);
  esds.U8(0x06);  // SL config
  esds.U8(1);
  esds.U8(0x02);
  mp4a.Add(esds);
  stsd.Add(mp4a);
  return stsd;
}

}  // namespace

bool WriteMp4(const std::string& path, const VideoTrack& video,
              const AudioTrack* audio, int rotation, std::string* error) {
  if (video.samples.empty() || video.sps.empty() || video.pps.empty()) {
    *error = "no frames";
    return false;
  }
  const bool with_audio = audio != nullptr && !audio->samples.empty() &&
                          !audio->config.empty() && audio->sample_rate > 0;
  TrackIndex vt = IndexOf(video.samples, 90000, false);
  TrackIndex at;
  if (with_audio) {
    at = IndexOf(audio->samples, static_cast<uint32_t>(audio->sample_rate),
                 true);
  }
  // The order in mdat: both tracks by time, so a player streaming the
  // file finds sound and picture next to each other.
  std::vector<std::pair<bool, size_t>> order;
  {
    size_t vi = 0;
    size_t ai = 0;
    const size_t an = with_audio ? audio->samples.size() : 0;
    while (vi < video.samples.size() || ai < an) {
      const bool take_video =
          ai >= an || (vi < video.samples.size() &&
                       video.samples[vi].pts_us <= audio->samples[ai].pts_us);
      if (take_video) {
        order.emplace_back(true, vi++);
      } else {
        order.emplace_back(false, ai++);
      }
    }
  }
  const uint64_t movie_ms = std::max<uint64_t>(
      vt.duration * 1000 / 90000,
      with_audio ? at.duration * 1000 / at.timescale : 0);
  Box ftyp("ftyp");
  ftyp.Text("isom", 4);
  ftyp.U32(0x200);
  ftyp.Text("isomiso2avc1mp41", 16);

  // The index is built twice: first to learn its size, then with the
  // offsets of the frames behind it.
  std::vector<uint8_t> moov_bytes;
  for (int pass = 0; pass < 2; pass++) {
    uint64_t offset = ftyp.Done().size() + moov_bytes.size() + 8;
    vt.offsets.assign(video.samples.size(), 0);
    at.offsets.assign(with_audio ? audio->samples.size() : 0, 0);
    for (const auto& o : order) {
      if (offset > 0xFFFFFFFFull) {
        *error = "too big";
        return false;
      }
      if (o.first) {
        vt.offsets[o.second] = static_cast<uint32_t>(offset);
        offset += video.samples[o.second].data.size();
      } else {
        at.offsets[o.second] = static_cast<uint32_t>(offset);
        offset += audio->samples[o.second].data.size();
      }
    }
    Box moov("moov");
    Box mvhd("mvhd");
    mvhd.U32(0);
    mvhd.U32(0);
    mvhd.U32(0);
    mvhd.U32(1000);
    mvhd.U32(static_cast<uint32_t>(movie_ms));
    mvhd.U32(0x00010000);
    mvhd.U16(0x0100);
    mvhd.Zeros(10);
    Matrix(&mvhd, 0, 0, 0);
    mvhd.Zeros(24);
    mvhd.U32(with_audio ? 3 : 2);
    moov.Add(mvhd);
    Box vmhd("vmhd");
    vmhd.U32(1);
    vmhd.Zeros(8);
    moov.Add(Trak(1, vt, movie_ms, "vide", "VideoHandler", vmhd,
                  VideoStsd(video), false, rotation, video.width,
                  video.height, false));
    if (with_audio) {
      Box smhd("smhd");
      smhd.U32(0);
      smhd.U32(0);
      moov.Add(Trak(2, at, movie_ms, "soun", "SoundHandler", smhd,
                    AudioStsd(*audio), true, 0, 0, 0, true));
    }
    const std::vector<uint8_t> built = moov.Done();
    if (pass == 1 && built.size() != moov_bytes.size()) {
      *error = "index size changed";
      return false;
    }
    moov_bytes = built;
  }
  uint64_t payload = 0;
  for (const auto& o : order) {
    payload += o.first ? video.samples[o.second].data.size()
                       : audio->samples[o.second].data.size();
  }
  FILE* f = fopen(path.c_str(), "wb");
  if (f == nullptr) {
    *error = "cannot write " + path;
    return false;
  }
  bool ok = true;
  auto put = [&](const uint8_t* data, size_t size) {
    if (ok && size > 0 && fwrite(data, 1, size, f) != size) {
      ok = false;
    }
  };
  const std::vector<uint8_t> head = ftyp.Done();
  put(head.data(), head.size());
  put(moov_bytes.data(), moov_bytes.size());
  const uint32_t mdat_size = static_cast<uint32_t>(payload + 8);
  const uint8_t mdat[8] = {static_cast<uint8_t>(mdat_size >> 24),
                           static_cast<uint8_t>(mdat_size >> 16),
                           static_cast<uint8_t>(mdat_size >> 8),
                           static_cast<uint8_t>(mdat_size),
                           'm', 'd', 'a', 't'};
  put(mdat, 8);
  for (const auto& o : order) {
    const std::vector<uint8_t>& d = o.first ? video.samples[o.second].data
                                            : audio->samples[o.second].data;
    put(d.data(), d.size());
  }
  if (fclose(f) != 0) {
    ok = false;
  }
  if (!ok) {
    *error = "writing " + path + " failed";
  }
  return ok;
}

}  // namespace zen_film
