#ifndef RUNNER_ZEN_CALL_MIXER_H_
#define RUNNER_ZEN_CALL_MIXER_H_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <vector>

// Mixes the sounds of a call recording (zen_call_recorder.cc): any number
// of sources of interleaved 16-bit samples at one rate and channel count,
// added up and written at the pace of a clock.
//
//  - The clock sets the pace, not the sources: a source that delivers
//    nothing (a stream that is paused, a muted microphone, one that has not
//    started yet) adds silence, and that silence belongs in the file.
//  - While recording, the mix stays |latency| seconds behind the clock, so
//    a source that is merely late still lands in its place.
//  - A source never keeps more than |max_buffered| seconds waiting: older
//    samples are dropped so the sources never drift apart.
//
// Thread-safe: sources are fed from the sound server's thread and the mix
// is taken on the writer's.
class ZenCallMixer {
 public:
  ZenCallMixer(int rate, int channels, double latency, double max_buffered)
      : rate_(rate),
        channels_(channels),
        latency_(latency),
        max_buffered_(static_cast<size_t>(max_buffered * rate) * channels) {}

  // A new source; its id is never given again.
  int AddSource() {
    std::lock_guard<std::mutex> lock(mutex_);
    const int id = next_id_++;
    sources_.emplace(id, std::deque<int16_t>());
    return id;
  }

  // The source ends: what it still holds is mixed in, then it goes.
  void Finish(int id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sources_.find(id);
    if (it == sources_.end()) return;
    if (it->second.empty()) {
      sources_.erase(it);
    } else {
      finished_.insert(id);
    }
  }

  // Sources still kept (for tests).
  size_t sources() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sources_.size();
  }

  // Adds |count| samples (whole frames: every channel) to source |id|.
  void Push(int id, const int16_t* samples, size_t count) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sources_.find(id);
    if (it == sources_.end() || samples == nullptr) return;
    std::deque<int16_t>& queue = it->second;
    queue.insert(queue.end(), samples, samples + count);
    if (queue.size() > max_buffered_) {
      size_t extra = queue.size() - max_buffered_;
      // Whole frames only, so the channels stay in their places.
      extra = (extra + channels_ - 1) / channels_ * channels_;
      queue.erase(queue.begin(),
                  queue.begin() + std::min(extra, queue.size()));
    }
  }

  // Appends to |out| the mix of everything due |seconds| after the start
  // (less the latency, unless this is the |last| pull) and returns how many
  // samples it added.
  size_t Pull(double seconds, bool last, std::vector<int16_t>* out) {
    std::lock_guard<std::mutex> lock(mutex_);
    const double at = std::max(0.0, last ? seconds : seconds - latency_);
    const uint64_t due = static_cast<uint64_t>(at * rate_) * channels_;
    if (due <= written_) return 0;
    const size_t n = static_cast<size_t>(due - written_);
    const size_t start = out->size();
    out->resize(start + n);
    for (size_t i = 0; i < n; ++i) {
      int32_t sum = 0;
      for (auto& source : sources_) {
        std::deque<int16_t>& queue = source.second;
        if (!queue.empty()) {
          sum += queue.front();
          queue.pop_front();
        }
      }
      (*out)[start + i] = static_cast<int16_t>(
          std::max<int32_t>(INT16_MIN, std::min<int32_t>(INT16_MAX, sum)));
    }
    written_ = due;
    for (auto it = finished_.begin(); it != finished_.end();) {
      auto source = sources_.find(*it);
      if (source == sources_.end() || source->second.empty()) {
        if (source != sources_.end()) sources_.erase(source);
        it = finished_.erase(it);
      } else {
        ++it;
      }
    }
    return n;
  }

  // Samples mixed so far (all channels).
  uint64_t written() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return written_;
  }

 private:
  const int rate_;
  const int channels_;
  const double latency_;
  const size_t max_buffered_;
  mutable std::mutex mutex_;
  std::map<int, std::deque<int16_t>> sources_;
  std::set<int> finished_;
  int next_id_ = 1;
  uint64_t written_ = 0;
};

#endif  // RUNNER_ZEN_CALL_MIXER_H_
