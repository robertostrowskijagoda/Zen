#include "media_transfer_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "utils.h"

namespace media_transfer_bridge {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
HWND g_window = nullptr;

// The files (not folders) in [drop], as UTF-8 paths.
std::vector<std::string> DropPaths(HDROP drop) {
  std::vector<std::string> paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT length = DragQueryFileW(drop, i, nullptr, 0);
    if (length == 0) {
      continue;
    }
    std::wstring path(length + 1, L'\0');
    if (DragQueryFileW(drop, i, path.data(), length + 1) == 0) {
      continue;
    }
    path.resize(length);
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      continue;
    }
    const std::string utf8 = Utf8FromUtf16(path.c_str());
    if (!utf8.empty()) {
      paths.push_back(utf8);
    }
  }
  return paths;
}

// The bytes of clipboard [format] (the clipboard is open), if it is there.
bool ReadFormat(UINT format, std::vector<uint8_t>* out) {
  if (format == 0 || !IsClipboardFormatAvailable(format)) {
    return false;
  }
  HANDLE handle = GetClipboardData(format);
  if (handle == nullptr) {
    return false;
  }
  const SIZE_T size = GlobalSize(handle);
  const void* data = GlobalLock(handle);
  if (data == nullptr) {
    return false;
  }
  const uint8_t* start = static_cast<const uint8_t*>(data);
  out->assign(start, start + size);
  GlobalUnlock(handle);
  return !out->empty();
}

// A CF_DIB bitmap (a BITMAPINFO and its pixels) as a BMP file.
bool DibToBmp(const std::vector<uint8_t>& dib, std::vector<uint8_t>* bmp) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) {
    return false;
  }
  BITMAPINFOHEADER header;
  std::memcpy(&header, dib.data(), sizeof(header));
  if (header.biSize < sizeof(BITMAPINFOHEADER) || header.biSize > dib.size() ||
      header.biWidth <= 0 || header.biHeight == 0) {
    return false;
  }
  DWORD colors = header.biClrUsed;
  if (colors == 0 && header.biBitCount <= 8) {
    colors = 1u << header.biBitCount;
  }
  // Colour masks follow a plain header for BI_BITFIELDS.
  const DWORD masks = header.biSize == sizeof(BITMAPINFOHEADER) &&
                              header.biCompression == BI_BITFIELDS
                          ? 12
                          : 0;
  BITMAPFILEHEADER file = {};
  file.bfType = 0x4D42;  // "BM"
  file.bfSize = static_cast<DWORD>(sizeof(file) + dib.size());
  file.bfOffBits = static_cast<DWORD>(sizeof(file) + header.biSize + masks +
                                      colors * 4);
  bmp->resize(sizeof(file));
  std::memcpy(bmp->data(), &file, sizeof(file));
  bmp->insert(bmp->end(), dib.begin(), dib.end());
  return true;
}

EncodableValue Picture(const char* name, std::vector<uint8_t> bytes) {
  return EncodableValue(EncodableMap{
      {EncodableValue("name"), EncodableValue(std::string(name))},
      {EncodableValue("bytes"), EncodableValue(std::move(bytes))},
  });
}

EncodableList ReadClipboard(bool text_first) {
  EncodableList items;
  if (!OpenClipboard(g_window)) {
    return items;
  }
  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE handle = GetClipboardData(CF_HDROP);
    if (handle != nullptr) {
      for (const std::string& path : DropPaths(static_cast<HDROP>(handle))) {
        items.push_back(EncodableValue(EncodableMap{
            {EncodableValue("path"), EncodableValue(path)},
        }));
      }
    }
  } else if (!(text_first && IsClipboardFormatAvailable(CF_UNICODETEXT))) {
    static const UINT gif = RegisterClipboardFormatW(L"GIF");
    static const UINT png = RegisterClipboardFormatW(L"PNG");
    std::vector<uint8_t> bytes;
    std::vector<uint8_t> dib;
    if (ReadFormat(gif, &bytes)) {
      items.push_back(Picture("schowek.gif", std::move(bytes)));
    } else if (ReadFormat(png, &bytes)) {
      items.push_back(Picture("schowek.png", std::move(bytes)));
    } else if (ReadFormat(CF_DIB, &dib) && DibToBmp(dib, &bytes)) {
      items.push_back(Picture("schowek.bmp", std::move(bytes)));
    }
  }
  CloseClipboard();
  return items;
}

}  // namespace

void Register(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "zen/media_transfer",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "read") {
          result->NotImplemented();
          return;
        }
        bool text_first = false;
        if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
          const auto it = args->find(EncodableValue("textFirst"));
          if (it != args->end()) {
            if (const auto* value = std::get_if<bool>(&it->second)) {
              text_first = *value;
            }
          }
        }
        result->Success(EncodableValue(ReadClipboard(text_first)));
      });
  DragAcceptFiles(window, TRUE);
}

void OnDropFiles(HWND window, HDROP drop) {
  POINT point = {};
  const bool inside = DragQueryPoint(drop, &point) != FALSE;
  const std::vector<std::string> paths = DropPaths(drop);
  DragFinish(drop);
  if (!g_channel || paths.empty()) {
    return;
  }
  EncodableList list;
  for (const std::string& path : paths) {
    list.push_back(EncodableValue(path));
  }
  EncodableMap args = {{EncodableValue("paths"), EncodableValue(list)}};
  const double scale = FlutterDesktopGetDpiForHWND(window) / 96.0;
  if (inside && scale > 0) {
    args[EncodableValue("x")] = EncodableValue(point.x / scale);
    args[EncodableValue("y")] = EncodableValue(point.y / scale);
  }
  g_channel->InvokeMethod("drop",
                          std::make_unique<EncodableValue>(std::move(args)));
}

}  // namespace media_transfer_bridge
