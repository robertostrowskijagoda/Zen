// clang-format off
#include <windows.h>
// clang-format on

#include "video_bridge.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <objbase.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "local_links_common.h"

namespace video_bridge {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
using MethodResult = flutter::MethodResult<EncodableValue>;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::atomic<bool> g_cancelled{false};
std::atomic<bool> g_running{false};

// 100-nanosecond units per millisecond.
constexpr LONGLONG kPerMs = 10000;

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                       static_cast<int>(utf8.size()), nullptr,
                                       0);
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), size);
  return out;
}

// The picture size a film is compressed to: video_compressor.dart's
// scaledVideoSize.
std::pair<UINT32, UINT32> ScaledSize(UINT32 width, UINT32 height,
                                     UINT32 max_short) {
  if (width == 0 || height == 0) {
    return {0, 0};
  }
  const UINT32 shortest = std::min(width, height);
  if (shortest <= max_short) {
    return {width & ~1u, height & ~1u};
  }
  const double scale = static_cast<double>(max_short) / shortest;
  auto even = [](double v) {
    return std::max<UINT32>(2, static_cast<UINT32>(std::lround(v)) & ~1u);
  };
  return {even(width * scale), even(height * scale)};
}

struct Outcome {
  int64_t duration_ms = 0;
  UINT32 width = 0;
  UINT32 height = 0;
  int64_t bytes = 0;
};

struct Job {
  std::wstring input;
  std::wstring output;
  int64_t start_ms = 0;
  int64_t end_ms = -1;
  UINT32 max_short = 720;
  UINT32 video_bitrate = 2500000;
  UINT32 audio_bitrate = 128000;
};

#define VB_CHECK(expr)        \
  do {                        \
    const HRESULT hr_ = (expr); \
    if (FAILED(hr_)) {        \
      return hr_;             \
    }                         \
  } while (false)

void Progress(double fraction) {
  static std::chrono::steady_clock::time_point last;
  const auto now = std::chrono::steady_clock::now();
  if (fraction < 1.0 && now - last < std::chrono::milliseconds(250)) {
    return;
  }
  last = now;
  local_links::RunOnPlatformThread([fraction]() {
    if (g_channel) {
      g_channel->InvokeMethod(
          "progress",
          std::make_unique<EncodableValue>(EncodableMap{
              {EncodableValue("fraction"),
               EncodableValue(std::clamp(fraction, 0.0, 1.0))},
          }));
    }
  });
}

// The PCM the AAC encoder takes (16 bits, 44.1 or 48 kHz, one or two
// channels), from the reader; false when the sound cannot be had so.
bool SetUpAudio(IMFSourceReader* reader, ComPtr<IMFMediaType>* pcm) {
  const DWORD stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  if (FAILED(reader->SetStreamSelection(stream, TRUE))) {
    return false;
  }
  for (int attempt = 0; attempt < 2; attempt++) {
    ComPtr<IMFMediaType> want;
    if (FAILED(MFCreateMediaType(&want))) {
      break;
    }
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    want->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (attempt == 0) {
      want->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
      want->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
    }
    if (FAILED(reader->SetCurrentMediaType(stream, nullptr, want.Get()))) {
      continue;
    }
    ComPtr<IMFMediaType> got;
    if (FAILED(reader->GetCurrentMediaType(stream, &got))) {
      continue;
    }
    const UINT32 rate = MFGetAttributeUINT32(got.Get(),
                                             MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
    const UINT32 channels =
        MFGetAttributeUINT32(got.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
    if ((rate == 44100 || rate == 48000) && channels >= 1 && channels <= 2) {
      *pcm = got;
      return true;
    }
  }
  reader->SetStreamSelection(stream, FALSE);
  return false;
}

HRESULT Transcode(const Job& job, Outcome* outcome) {
  ComPtr<IMFAttributes> reader_attributes;
  VB_CHECK(MFCreateAttributes(&reader_attributes, 2));
  // Scaling and conversion to NV12 inside the reader.
  reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING,
                               TRUE);
  reader_attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  ComPtr<IMFSourceReader> reader;
  VB_CHECK(MFCreateSourceReaderFromURL(job.input.c_str(),
                                       reader_attributes.Get(), &reader));
  VB_CHECK(reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE));
  const DWORD video_in = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
  VB_CHECK(reader->SetStreamSelection(video_in, TRUE));

  LONGLONG duration = 0;
  {
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(reader->GetPresentationAttribute(
            static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
            &value))) {
      duration = static_cast<LONGLONG>(value.uhVal.QuadPart);
    }
    PropVariantClear(&value);
  }

  ComPtr<IMFMediaType> native;
  VB_CHECK(reader->GetNativeMediaType(video_in, 0, &native));
  UINT32 width = 0;
  UINT32 height = 0;
  VB_CHECK(MFGetAttributeSize(native.Get(), MF_MT_FRAME_SIZE, &width, &height));
  UINT32 rate_num = 30;
  UINT32 rate_den = 1;
  if (FAILED(MFGetAttributeRatio(native.Get(), MF_MT_FRAME_RATE, &rate_num,
                                 &rate_den)) ||
      rate_num == 0 || rate_den == 0) {
    rate_num = 30;
    rate_den = 1;
  }
  const UINT32 rotation =
      MFGetAttributeUINT32(native.Get(), MF_MT_VIDEO_ROTATION, 0);

  auto [out_w, out_h] = ScaledSize(width, height, job.max_short);
  ComPtr<IMFMediaType> nv12;
  VB_CHECK(MFCreateMediaType(&nv12));
  nv12->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  nv12->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  MFSetAttributeSize(nv12.Get(), MF_MT_FRAME_SIZE, out_w, out_h);
  if (FAILED(reader->SetCurrentMediaType(video_in, nullptr, nv12.Get()))) {
    // No scaling here: the film keeps its size, the bit rate still holds.
    out_w = width & ~1u;
    out_h = height & ~1u;
    MFSetAttributeSize(nv12.Get(), MF_MT_FRAME_SIZE, out_w, out_h);
    VB_CHECK(reader->SetCurrentMediaType(video_in, nullptr, nv12.Get()));
  }
  ComPtr<IMFMediaType> frames;
  VB_CHECK(reader->GetCurrentMediaType(video_in, &frames));

  ComPtr<IMFMediaType> pcm;
  const bool audio = SetUpAudio(reader.Get(), &pcm);

  ComPtr<IMFAttributes> writer_attributes;
  VB_CHECK(MFCreateAttributes(&writer_attributes, 3));
  writer_attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  writer_attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
  writer_attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE,
                             MFTranscodeContainerType_MPEG4);
  ComPtr<IMFSinkWriter> writer;
  VB_CHECK(MFCreateSinkWriterFromURL(job.output.c_str(), nullptr,
                                     writer_attributes.Get(), &writer));

  ComPtr<IMFMediaType> h264;
  VB_CHECK(MFCreateMediaType(&h264));
  h264->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  h264->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  h264->SetUINT32(MF_MT_AVG_BITRATE, job.video_bitrate);
  h264->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  h264->SetUINT32(MF_MT_VIDEO_ROTATION, rotation);
  MFSetAttributeSize(h264.Get(), MF_MT_FRAME_SIZE, out_w, out_h);
  MFSetAttributeRatio(h264.Get(), MF_MT_FRAME_RATE, rate_num, rate_den);
  MFSetAttributeRatio(h264.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  DWORD video_out = 0;
  VB_CHECK(writer->AddStream(h264.Get(), &video_out));
  VB_CHECK(writer->SetInputMediaType(video_out, frames.Get(), nullptr));

  DWORD audio_out = 0;
  bool write_audio = false;
  if (audio) {
    ComPtr<IMFMediaType> aac;
    VB_CHECK(MFCreateMediaType(&aac));
    aac->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    aac->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    aac->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    aac->SetUINT32(
        MF_MT_AUDIO_SAMPLES_PER_SECOND,
        MFGetAttributeUINT32(pcm.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000));
    aac->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS,
                   MFGetAttributeUINT32(pcm.Get(), MF_MT_AUDIO_NUM_CHANNELS, 2));
    // The AAC encoder takes 12000, 16000, 20000 or 24000 bytes a second.
    const UINT32 per_second =
        std::clamp<UINT32>((job.audio_bitrate / 8 / 4000) * 4000, 12000, 24000);
    aac->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, per_second);
    write_audio = SUCCEEDED(writer->AddStream(aac.Get(), &audio_out)) &&
                  SUCCEEDED(writer->SetInputMediaType(audio_out, pcm.Get(),
                                                      nullptr));
    if (!write_audio) {
      reader->SetStreamSelection(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), FALSE);
    }
  }
  VB_CHECK(writer->BeginWriting());

  const LONGLONG start = std::max<int64_t>(0, job.start_ms) * kPerMs;
  const LONGLONG end = job.end_ms < 0 ? (duration > 0 ? duration : LLONG_MAX)
                                      : job.end_ms * kPerMs;
  const LONGLONG last = duration > 0 ? std::min(end, duration) : end;
  const LONGLONG span = std::max<LONGLONG>(1, last - start);
  {
    PROPVARIANT position;
    PropVariantInit(&position);
    position.vt = VT_I8;
    position.hVal.QuadPart = start;
    reader->SetCurrentPosition(GUID_NULL, position);
  }

  // Which of the reader's streams is the picture (the others: the sound).
  std::map<DWORD, bool> is_video;
  bool video_done = false;
  bool audio_done = !write_audio;
  LONGLONG last_video = 0;
  while (!video_done || !audio_done) {
    if (g_cancelled.load()) {
      return E_ABORT;
    }
    DWORD index = 0;
    DWORD flags = 0;
    LONGLONG at = 0;
    ComPtr<IMFSample> sample;
    VB_CHECK(reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0, &index, &flags, &at,
        &sample));
    auto known = is_video.find(index);
    if (known == is_video.end()) {
      ComPtr<IMFMediaType> type;
      GUID major = GUID_NULL;
      if (SUCCEEDED(reader->GetCurrentMediaType(index, &type))) {
        type->GetGUID(MF_MT_MAJOR_TYPE, &major);
      }
      known = is_video.emplace(index, major == MFMediaType_Video).first;
    }
    const bool video = known->second;
    bool& done = video ? video_done : audio_done;
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      done = true;
      continue;
    }
    if (!sample || at < start) {
      continue;
    }
    if (at > end) {
      done = true;
      reader->SetStreamSelection(index, FALSE);
      continue;
    }
    sample->SetSampleTime(at - start);
    VB_CHECK(writer->WriteSample(video ? video_out : audio_out, sample.Get()));
    if (video) {
      last_video = std::max(last_video, at - start);
      Progress(static_cast<double>(at - start) / span);
    }
  }
  VB_CHECK(writer->Finalize());
  Progress(1.0);

  WIN32_FILE_ATTRIBUTE_DATA file{};
  if (GetFileAttributesExW(job.output.c_str(), GetFileExInfoStandard, &file)) {
    outcome->bytes = (static_cast<int64_t>(file.nFileSizeHigh) << 32) |
                     file.nFileSizeLow;
  }
  const bool turned = rotation == 90 || rotation == 270;
  outcome->width = turned ? out_h : out_w;
  outcome->height = turned ? out_w : out_h;
  outcome->duration_ms = last_video / kPerMs;
  return S_OK;
}

// The picture [pixels] (BGRA, [w] × [h]) turned [rotation] degrees
// clockwise.
std::vector<uint8_t> Turn(const std::vector<uint8_t>& pixels, UINT32 w,
                          UINT32 h, UINT32 rotation, UINT32* out_w,
                          UINT32* out_h) {
  const bool sideways = rotation == 90 || rotation == 270;
  *out_w = sideways ? h : w;
  *out_h = sideways ? w : h;
  if (rotation != 90 && rotation != 180 && rotation != 270) {
    return pixels;
  }
  std::vector<uint8_t> out(pixels.size());
  for (UINT32 y = 0; y < h; y++) {
    for (UINT32 x = 0; x < w; x++) {
      UINT32 tx = x;
      UINT32 ty = y;
      if (rotation == 90) {
        tx = h - 1 - y;
        ty = x;
      } else if (rotation == 180) {
        tx = w - 1 - x;
        ty = h - 1 - y;
      } else {
        tx = y;
        ty = w - 1 - x;
      }
      const size_t from = (static_cast<size_t>(y) * w + x) * 4;
      const size_t to = (static_cast<size_t>(ty) * *out_w + tx) * 4;
      std::copy(pixels.begin() + from, pixels.begin() + from + 4,
                out.begin() + to);
    }
  }
  return out;
}

// [pixels] (BGRA) as a JPEG, through the Windows Imaging Component.
HRESULT EncodeJpeg(const std::vector<uint8_t>& pixels, UINT32 w, UINT32 h,
                   std::vector<uint8_t>* jpeg) {
  ComPtr<IWICImagingFactory> factory;
  VB_CHECK(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
  ComPtr<IStream> stream;
  VB_CHECK(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
  ComPtr<IWICBitmapEncoder> encoder;
  VB_CHECK(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr,
                                  &encoder));
  VB_CHECK(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> options;
  VB_CHECK(encoder->CreateNewFrame(&frame, &options));
  VB_CHECK(frame->Initialize(options.Get()));
  VB_CHECK(frame->SetSize(w, h));
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  VB_CHECK(frame->SetPixelFormat(&format));
  if (format != GUID_WICPixelFormat24bppBGR) {
    return E_FAIL;
  }
  std::vector<uint8_t> bgr(static_cast<size_t>(w) * h * 3);
  for (size_t i = 0, n = static_cast<size_t>(w) * h; i < n; i++) {
    bgr[3 * i] = pixels[4 * i];
    bgr[3 * i + 1] = pixels[4 * i + 1];
    bgr[3 * i + 2] = pixels[4 * i + 2];
  }
  VB_CHECK(frame->WritePixels(h, w * 3, static_cast<UINT>(bgr.size()),
                              bgr.data()));
  VB_CHECK(frame->Commit());
  VB_CHECK(encoder->Commit());
  STATSTG stat{};
  VB_CHECK(stream->Stat(&stat, STATFLAG_NONAME));
  LARGE_INTEGER start{};
  VB_CHECK(stream->Seek(start, STREAM_SEEK_SET, nullptr));
  jpeg->resize(static_cast<size_t>(stat.cbSize.QuadPart));
  ULONG read = 0;
  VB_CHECK(stream->Read(jpeg->data(), static_cast<ULONG>(jpeg->size()),
                        &read));
  jpeg->resize(read);
  return S_OK;
}

// One frame of [input] at [at_ms] as a JPEG, its long side at most
// [max_side], turned upright: the poster of a film.
HRESULT Thumbnail(const std::wstring& input, int64_t at_ms, UINT32 max_side,
                  std::vector<uint8_t>* jpeg) {
  ComPtr<IMFAttributes> attributes;
  VB_CHECK(MFCreateAttributes(&attributes, 1));
  attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING,
                        TRUE);
  ComPtr<IMFSourceReader> reader;
  VB_CHECK(MFCreateSourceReaderFromURL(input.c_str(), attributes.Get(),
                                       &reader));
  const DWORD video = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
  VB_CHECK(reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE));
  VB_CHECK(reader->SetStreamSelection(video, TRUE));
  ComPtr<IMFMediaType> native;
  VB_CHECK(reader->GetNativeMediaType(video, 0, &native));
  UINT32 width = 0;
  UINT32 height = 0;
  VB_CHECK(MFGetAttributeSize(native.Get(), MF_MT_FRAME_SIZE, &width, &height));
  const UINT32 rotation =
      MFGetAttributeUINT32(native.Get(), MF_MT_VIDEO_ROTATION, 0);
  const UINT32 longest = std::max(width, height);
  const double scale =
      longest > max_side ? static_cast<double>(max_side) / longest : 1.0;
  ComPtr<IMFMediaType> rgb;
  VB_CHECK(MFCreateMediaType(&rgb));
  rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  MFSetAttributeSize(rgb.Get(), MF_MT_FRAME_SIZE,
                     std::max<UINT32>(2, static_cast<UINT32>(width * scale)) & ~1u,
                     std::max<UINT32>(2, static_cast<UINT32>(height * scale)) & ~1u);
  if (FAILED(reader->SetCurrentMediaType(video, nullptr, rgb.Get()))) {
    MFSetAttributeSize(rgb.Get(), MF_MT_FRAME_SIZE, width, height);
    VB_CHECK(reader->SetCurrentMediaType(video, nullptr, rgb.Get()));
  }
  ComPtr<IMFMediaType> current;
  VB_CHECK(reader->GetCurrentMediaType(video, &current));
  UINT32 w = 0;
  UINT32 h = 0;
  VB_CHECK(MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h));
  if (at_ms > 0) {
    PROPVARIANT position;
    PropVariantInit(&position);
    position.vt = VT_I8;
    position.hVal.QuadPart = at_ms * kPerMs;
    reader->SetCurrentPosition(GUID_NULL, position);
  }
  ComPtr<IMFSample> sample;
  for (int tries = 0; tries < 64 && !sample; tries++) {
    DWORD index = 0;
    DWORD flags = 0;
    LONGLONG at = 0;
    VB_CHECK(reader->ReadSample(video, 0, &index, &flags, &at, &sample));
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      break;
    }
  }
  if (!sample) {
    return MF_E_END_OF_STREAM;
  }
  ComPtr<IMFMediaBuffer> buffer;
  VB_CHECK(sample->ConvertToContiguousBuffer(&buffer));
  std::vector<uint8_t> pixels(static_cast<size_t>(w) * h * 4);
  ComPtr<IMF2DBuffer> planar;
  BYTE* scan0 = nullptr;
  LONG pitch = 0;
  if (SUCCEEDED(buffer.As(&planar)) &&
      SUCCEEDED(planar->Lock2D(&scan0, &pitch))) {
    for (UINT32 y = 0; y < h; y++) {
      std::copy(scan0 + static_cast<LONG>(y) * pitch,
                scan0 + static_cast<LONG>(y) * pitch + w * 4,
                pixels.begin() + static_cast<size_t>(y) * w * 4);
    }
    planar->Unlock2D();
  } else {
    BYTE* data = nullptr;
    DWORD length = 0;
    VB_CHECK(buffer->Lock(&data, nullptr, &length));
    const size_t row = static_cast<size_t>(w) * 4;
    for (UINT32 y = 0; y < h && (y + 1) * row <= length; y++) {
      std::copy(data + y * row, data + (y + 1) * row,
                pixels.begin() + y * row);
    }
    buffer->Unlock();
  }
  UINT32 shown_w = 0;
  UINT32 shown_h = 0;
  const std::vector<uint8_t> upright =
      Turn(pixels, w, h, rotation, &shown_w, &shown_h);
  return EncodeJpeg(upright, shown_w, shown_h, jpeg);
}

void Reply(std::shared_ptr<MethodResult> result, EncodableValue value) {
  local_links::RunOnPlatformThread(
      [result, value = std::move(value)]() { result->Success(value); });
}

void Fail(std::shared_ptr<MethodResult> result, std::string code,
          std::string message) {
  local_links::RunOnPlatformThread(
      [result, code = std::move(code), message = std::move(message)]() {
        result->Error(code, message);
      });
}

void Handle(const flutter::MethodCall<EncodableValue>& call,
            std::shared_ptr<MethodResult> result) {
  const std::string& method = call.method_name();
  if (method == "isAvailable") {
    local_links::RunDetached([result]() {
      const bool ok = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
      if (ok) {
        MFShutdown();
      }
      Reply(result, EncodableValue(ok));
    });
    return;
  }
  if (method == "cancel") {
    g_cancelled = true;
    result->Success();
    return;
  }
  if (method == "thumbnail") {
    const EncodableValue* args = call.arguments();
    const std::wstring input = Wide(local_links::ArgString(args, "input"));
    const int64_t at_ms = local_links::ArgInt(args, "atMs", 0);
    const UINT32 max_side =
        static_cast<UINT32>(local_links::ArgInt(args, "maxSide", 480));
    if (input.empty()) {
      result->Success();
      return;
    }
    local_links::RunDetached([result, input, at_ms, max_side]() {
      std::vector<uint8_t> jpeg;
      if (SUCCEEDED(MFStartup(MF_VERSION))) {
        if (FAILED(Thumbnail(input, at_ms, std::max<UINT32>(16, max_side),
                             &jpeg))) {
          jpeg.clear();
        }
        MFShutdown();
      }
      Reply(result, jpeg.empty() ? EncodableValue() : EncodableValue(jpeg));
    });
    return;
  }
  if (method == "compress") {
    const EncodableValue* args = call.arguments();
    Job job;
    job.input = Wide(local_links::ArgString(args, "input"));
    job.output = Wide(local_links::ArgString(args, "output"));
    job.start_ms = local_links::ArgInt(args, "startMs", 0);
    job.end_ms = local_links::ArgInt(args, "endMs", -1);
    job.max_short =
        static_cast<UINT32>(local_links::ArgInt(args, "maxShortSide", 720));
    job.video_bitrate = static_cast<UINT32>(
        local_links::ArgInt(args, "videoBitrate", 2500000));
    job.audio_bitrate = static_cast<UINT32>(
        local_links::ArgInt(args, "audioBitrate", 128000));
    if (job.input.empty() || job.output.empty()) {
      result->Error("failed", "input and output are needed");
      return;
    }
    if (g_running.exchange(true)) {
      result->Error("failed", "a film is being compressed already");
      return;
    }
    g_cancelled = false;
    local_links::RunDetached([result, job]() {
      HRESULT hr = MFStartup(MF_VERSION);
      Outcome outcome;
      if (SUCCEEDED(hr)) {
        hr = Transcode(job, &outcome);
        MFShutdown();
      }
      g_running = false;
      if (FAILED(hr)) {
        DeleteFileW(job.output.c_str());
        if (hr == E_ABORT) {
          Fail(result, "cancelled", "cancelled");
        } else {
          char code[32];
          std::snprintf(code, sizeof(code), "0x%08lX",
                        static_cast<unsigned long>(hr));
          Fail(result, "failed",
               std::string("Media Foundation error ") + code);
        }
        return;
      }
      Reply(result,
            EncodableValue(EncodableMap{
                {EncodableValue("durationMs"),
                 EncodableValue(static_cast<int64_t>(outcome.duration_ms))},
                {EncodableValue("width"),
                 EncodableValue(static_cast<int32_t>(outcome.width))},
                {EncodableValue("height"),
                 EncodableValue(static_cast<int32_t>(outcome.height))},
                {EncodableValue("bytes"),
                 EncodableValue(static_cast<int64_t>(outcome.bytes))},
            }));
    });
    return;
  }
  result->NotImplemented();
}

}  // namespace

void Register(flutter::BinaryMessenger* messenger) {
  local_links::InitPlatformThread();
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "zen/video", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<MethodResult> result) {
        Handle(call, std::shared_ptr<MethodResult>(std::move(result)));
      });
}

}  // namespace video_bridge
