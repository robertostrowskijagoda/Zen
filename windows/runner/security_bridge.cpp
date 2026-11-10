#include "security_bridge.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <ncrypt.h>
#include <tlhelp32.h>

#include <cwctype>
#include <memory>
#include <string>
#include <vector>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace security_bridge {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr wchar_t kKeyName[] = L"ZenMasterWrapV1";
constexpr uint8_t kTpm = 'T';
// Tokens are sealed by the TPM only: DPAPI would hand the secret to any
// program running as this Windows user, with no Windows Hello in between.

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_window_channel;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_vault_channel;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_integrity_channel;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_clipboard_channel;
std::function<HWND()> g_window;

const std::vector<uint8_t>* BytesArg(const flutter::MethodCall<EncodableValue>& call,
                                     const char* name) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (!args) return nullptr;
  auto it = args->find(EncodableValue(name));
  if (it == args->end()) return nullptr;
  return std::get_if<std::vector<uint8_t>>(&it->second);
}

// ---- TPM -------------------------------------------------------------

class Tpm {
 public:
  Tpm() {
    if (NCryptOpenStorageProvider(&provider_, MS_PLATFORM_CRYPTO_PROVIDER, 0) !=
        ERROR_SUCCESS) {
      provider_ = 0;
    }
  }
  ~Tpm() {
    if (key_) NCryptFreeObject(key_);
    if (provider_) NCryptFreeObject(provider_);
  }

  bool present() const { return provider_ != 0; }

  bool OpenKey(bool create) {
    if (!provider_) return false;
    if (key_) return true;
    if (NCryptOpenKey(provider_, &key_, kKeyName, 0, 0) == ERROR_SUCCESS) {
      return true;
    }
    key_ = 0;
    if (!create) return false;
    if (NCryptCreatePersistedKey(provider_, &key_, BCRYPT_RSA_ALGORITHM,
                                 kKeyName, 0, 0) != ERROR_SUCCESS) {
      key_ = 0;
      return false;
    }
    DWORD length = 2048;
    NCryptSetProperty(key_, NCRYPT_LENGTH_PROPERTY,
                      reinterpret_cast<PBYTE>(&length), sizeof(length), 0);
    if (NCryptFinalizeKey(key_, 0) != ERROR_SUCCESS) {
      NCryptFreeObject(key_);
      key_ = 0;
      return false;
    }
    return true;
  }

  bool Encrypt(const std::vector<uint8_t>& in, std::vector<uint8_t>* out) {
    if (!OpenKey(true)) return false;
    BCRYPT_OAEP_PADDING_INFO pad{BCRYPT_SHA1_ALGORITHM, nullptr, 0};
    DWORD size = 0;
    if (NCryptEncrypt(key_, const_cast<PBYTE>(in.data()),
                      static_cast<DWORD>(in.size()), &pad, nullptr, 0, &size,
                      NCRYPT_PAD_OAEP_FLAG) != ERROR_SUCCESS) {
      return false;
    }
    out->resize(size);
    if (NCryptEncrypt(key_, const_cast<PBYTE>(in.data()),
                      static_cast<DWORD>(in.size()), &pad, out->data(), size,
                      &size, NCRYPT_PAD_OAEP_FLAG) != ERROR_SUCCESS) {
      return false;
    }
    out->resize(size);
    return true;
  }

  bool Decrypt(const uint8_t* in, size_t n, std::vector<uint8_t>* out) {
    if (!OpenKey(false)) return false;
    BCRYPT_OAEP_PADDING_INFO pad{BCRYPT_SHA1_ALGORITHM, nullptr, 0};
    DWORD size = 0;
    if (NCryptDecrypt(key_, const_cast<PBYTE>(in), static_cast<DWORD>(n), &pad,
                      nullptr, 0, &size, NCRYPT_PAD_OAEP_FLAG) != ERROR_SUCCESS) {
      return false;
    }
    out->resize(size);
    if (NCryptDecrypt(key_, const_cast<PBYTE>(in), static_cast<DWORD>(n), &pad,
                      out->data(), size, &size,
                      NCRYPT_PAD_OAEP_FLAG) != ERROR_SUCCESS) {
      return false;
    }
    out->resize(size);
    return true;
  }

  void Delete() {
    if (OpenKey(false)) {
      NCryptDeleteKey(key_, 0);  // frees the handle too
      key_ = 0;
    }
  }

 private:
  NCRYPT_PROV_HANDLE provider_ = 0;
  NCRYPT_KEY_HANDLE key_ = 0;
};

// Residual risk (documented): the TPM key has no UI policy, so while
// biometric unlock is on, a program already running as this Windows user
// could ask the TPM to unwrap the sealed token without Windows Hello (Hello
// is asked by the app, on the Dart side). That is why biometric unlock is
// off on Windows until the person turns it on, and turning it off deletes
// both the token and this key.
void HandleVault(const flutter::MethodCall<EncodableValue>& call,
                 std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  Tpm tpm;
  if (method == "available") {
    // Without a TPM there is no biometric unlock (the password is the way
    // in); Windows Hello availability is checked on the Dart side.
    result->Success(EncodableValue(tpm.present()));
    return;
  }
  if (method == "describe") {
    result->Success(EncodableValue(std::string(tpm.present() ? "TPM" : "brak")));
    return;
  }
  if (method == "wipe") {
    tpm.Delete();
    result->Success(EncodableValue(true));
    return;
  }
  const std::vector<uint8_t>* data = BytesArg(call, "data");
  if (!data || data->empty()) {
    result->Success();
    return;
  }
  if (method == "seal") {
    std::vector<uint8_t> sealed;
    if (!tpm.present() || !tpm.Encrypt(*data, &sealed)) {
      result->Success();
      return;
    }
    std::vector<uint8_t> out;
    out.push_back(kTpm);
    out.insert(out.end(), sealed.begin(), sealed.end());
    result->Success(EncodableValue(out));
    return;
  }
  if (method == "open") {
    std::vector<uint8_t> plain;
    bool ok = false;
    if ((*data)[0] == kTpm && data->size() > 1) {
      ok = tpm.Decrypt(data->data() + 1, data->size() - 1, &plain);
    }
    if (!ok) {
      result->Success();
      return;
    }
    result->Success(EncodableValue(plain));
    SecureZeroMemory(plain.data(), plain.size());
    return;
  }
  result->NotImplemented();
}

// ---- integrity -------------------------------------------------------

// Whether a module of this process has one of marks in its name (lower
// case): Frida's library, for one.
bool ModuleNamed(const std::vector<std::wstring>& marks) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return false;
  MODULEENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  bool found = false;
  for (BOOL more = Module32FirstW(snapshot, &entry); more && !found;
       more = Module32NextW(snapshot, &entry)) {
    std::wstring name(entry.szModule);
    for (auto& c : name) c = static_cast<wchar_t>(towlower(c));
    for (const auto& mark : marks) {
      if (name.find(mark) != std::wstring::npos) {
        found = true;
        break;
      }
    }
  }
  CloseHandle(snapshot);
  return found;
}

// The answer of ZenSecurityBridge.kt's shape (device_integrity.dart): a
// debugger attached (in this process or from another), Frida's library
// loaded. Both mean someone is inside the process: the app then also
// refuses payments and the pyramid's power key.
EncodableMap Integrity() {
  EncodableList reasons;
  bool tampered = false;
  BOOL remote = FALSE;
  if (IsDebuggerPresent() ||
      (CheckRemoteDebuggerPresent(GetCurrentProcess(), &remote) && remote)) {
    reasons.push_back(EncodableValue("debugger"));
    tampered = true;
  }
  if (ModuleNamed({L"frida", L"gum-js"})) {
    reasons.push_back(EncodableValue("frida-loaded"));
    tampered = true;
  }
  return EncodableMap{
      {EncodableValue("rooted"), EncodableValue(false)},
      {EncodableValue("reasons"), EncodableValue(reasons)},
      {EncodableValue("debuggable"), EncodableValue(false)},
      {EncodableValue("tampered"), EncodableValue(tampered)},
      {EncodableValue("emulator"), EncodableValue(false)},
  };
}

// ---- clipboard -------------------------------------------------------

// Adds the registered clipboard format [name] holding the DWORD [value]
// to the clipboard that is open now.
void SetClipboardDword(const wchar_t* name, DWORD value) {
  UINT format = RegisterClipboardFormatW(name);
  if (!format) return;
  HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
  if (!data) return;
  auto* slot = static_cast<DWORD*>(GlobalLock(data));
  if (slot) {
    *slot = value;
    GlobalUnlock(data);
    if (SetClipboardData(format, data)) return;  // the clipboard owns it
  }
  GlobalFree(data);
}

// Puts [utf8] on the clipboard as text that stays out of the clipboard
// history (Win+V), the cloud clipboard and clipboard monitors.
bool CopySensitive(HWND owner, const std::string& utf8) {
  int length = 0;
  if (!utf8.empty()) {
    length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                 static_cast<int>(utf8.size()), nullptr, 0);
    if (length <= 0) return false;
  }
  HGLOBAL text = GlobalAlloc(GMEM_MOVEABLE, (length + 1) * sizeof(wchar_t));
  if (!text) return false;
  auto* buffer = static_cast<wchar_t*>(GlobalLock(text));
  if (!buffer) {
    GlobalFree(text);
    return false;
  }
  if (length > 0) {
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        buffer, length);
  }
  buffer[length] = L'\0';
  GlobalUnlock(text);
  if (!OpenClipboard(owner)) {
    GlobalFree(text);
    return false;
  }
  EmptyClipboard();
  if (!SetClipboardData(CF_UNICODETEXT, text)) {
    CloseClipboard();
    GlobalFree(text);
    return false;
  }
  SetClipboardDword(L"CanIncludeInClipboardHistory", 0);
  SetClipboardDword(L"CanUploadToCloudClipboard", 0);
  SetClipboardDword(L"ExcludeClipboardContentFromMonitorProcessing", 0);
  CloseClipboard();
  return true;
}

}  // namespace

void Register(flutter::BinaryMessenger* messenger,
              std::function<HWND()> window) {
  g_window = std::move(window);
  g_window_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "zen/secure_window",
      &flutter::StandardMethodCodec::GetInstance());
  g_window_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "setSecure") {
          result->NotImplemented();
          return;
        }
        bool secure = false;
        if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
          auto it = args->find(EncodableValue("secure"));
          if (it != args->end()) {
            if (const auto* b = std::get_if<bool>(&it->second)) secure = *b;
          }
        }
        HWND hwnd = g_window ? g_window() : nullptr;
        BOOL ok = FALSE;
        if (hwnd) {
          ok = SetWindowDisplayAffinity(
              hwnd, secure ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE);
          if (!ok && secure) {
            // Older Windows: shown black in captures instead.
            ok = SetWindowDisplayAffinity(hwnd, WDA_MONITOR);
          }
        }
        result->Success(EncodableValue(ok == TRUE));
      });
  g_vault_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "zen/keyvault", &flutter::StandardMethodCodec::GetInstance());
  g_vault_channel->SetMethodCallHandler(HandleVault);
  g_integrity_channel =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "zen/integrity",
          &flutter::StandardMethodCodec::GetInstance());
  g_integrity_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "check") {
          result->NotImplemented();
          return;
        }
        result->Success(EncodableValue(Integrity()));
      });
  g_clipboard_channel =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "zen/clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  g_clipboard_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "copySensitive") {
          result->NotImplemented();
          return;
        }
        const std::string* text = nullptr;
        if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
          auto it = args->find(EncodableValue("text"));
          if (it != args->end()) text = std::get_if<std::string>(&it->second);
        }
        HWND hwnd = g_window ? g_window() : nullptr;
        result->Success(
            EncodableValue(text != nullptr && CopySensitive(hwnd, *text)));
      });
}

}  // namespace security_bridge
