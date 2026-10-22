#ifndef RUNNER_ZEN_MEDIA_TRANSFER_H_
#define RUNNER_ZEN_MEDIA_TRANSFER_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Files dropped on Zen's window and pictures or files on the clipboard:
// method channel "zen/media_transfer" (see media_transfer.dart).
//  - "read" {textFirst} → [{name, path} | {name, bytes}]: files copied in a
//    file manager (text/uri-list), else a picture: image/gif as it is, any
//    other image as PNG. With textFirst, text on the clipboard gives [] so
//    Ctrl+V pastes the text;
//  - "drop" {paths, x, y} to Dart: files dropped on [window] (a GTK drop
//    site for text/uri-list), in logical pixels of [view].
void zen_media_transfer_register(FlPluginRegistry* registry, GtkWidget* window,
                                 GtkWidget* view);

#endif  // RUNNER_ZEN_MEDIA_TRANSFER_H_
