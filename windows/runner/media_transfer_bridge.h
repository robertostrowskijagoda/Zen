#ifndef RUNNER_MEDIA_TRANSFER_BRIDGE_H_
#define RUNNER_MEDIA_TRANSFER_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>
#include <shellapi.h>

// Files dropped on Zen's window and pictures or files on the clipboard:
// method channel "zen/media_transfer" (see media_transfer.dart).
//  - "read" {textFirst} → [{name, path} | {name, bytes}]: files copied in
//    Explorer (CF_HDROP), else a picture: a "GIF" or "PNG" clipboard format
//    as it is, or a CF_DIB bitmap as a BMP file. With textFirst, text on
//    the clipboard (CF_UNICODETEXT) gives [] so Ctrl+V pastes the text;
//  - "drop" {paths, x, y} to Dart: files dropped on the window
//    (WM_DROPFILES), at logical pixels of the Flutter view.
namespace media_transfer_bridge {

// Registers the channel and lets [window] (the top-level window) take
// dropped files.
void Register(flutter::BinaryMessenger* messenger, HWND window);

// WM_DROPFILES on [window]: hands the files to Dart and frees [drop].
void OnDropFiles(HWND window, HDROP drop);

}  // namespace media_transfer_bridge

#endif  // RUNNER_MEDIA_TRANSFER_BRIDGE_H_
