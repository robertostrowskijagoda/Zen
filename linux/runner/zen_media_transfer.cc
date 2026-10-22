#include "zen_media_transfer.h"

#include <cstring>
#include <string>
#include <vector>

namespace {

FlMethodChannel* g_channel = nullptr;
GtkWidget* g_view = nullptr;

// The local files (not folders) among [uris].
std::vector<std::string> PathsFromUris(gchar** uris) {
  std::vector<std::string> paths;
  if (uris == nullptr) {
    return paths;
  }
  for (gchar** uri = uris; *uri != nullptr; ++uri) {
    g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
    if (path != nullptr && g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
      paths.emplace_back(path);
    }
  }
  return paths;
}

void AddPicture(FlValue* list, const char* name, const guint8* data,
                size_t size) {
  FlValue* item = fl_value_new_map();
  fl_value_set_string_take(item, "name", fl_value_new_string(name));
  fl_value_set_string_take(item, "bytes", fl_value_new_uint8_list(data, size));
  fl_value_append_take(list, item);
}

FlValue* ReadClipboard(bool text_first) {
  FlValue* list = fl_value_new_list();
  GtkClipboard* board = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gchar** uris = gtk_clipboard_wait_for_uris(board);
  const std::vector<std::string> paths = PathsFromUris(uris);
  g_strfreev(uris);
  if (!paths.empty()) {
    for (const std::string& path : paths) {
      FlValue* item = fl_value_new_map();
      fl_value_set_string_take(item, "path", fl_value_new_string(path.c_str()));
      fl_value_append_take(list, item);
    }
    return list;
  }
  if (text_first && gtk_clipboard_wait_is_text_available(board)) {
    return list;
  }
  GtkSelectionData* gif = gtk_clipboard_wait_for_contents(
      board, gdk_atom_intern_static_string("image/gif"));
  if (gif != nullptr) {
    gint length = 0;
    const guchar* data = gtk_selection_data_get_data_with_length(gif, &length);
    const bool found = data != nullptr && length > 0;
    if (found) {
      AddPicture(list, "schowek.gif", data, static_cast<size_t>(length));
    }
    gtk_selection_data_free(gif);
    if (found) {
      return list;
    }
  }
  GdkPixbuf* image = gtk_clipboard_wait_for_image(board);
  if (image != nullptr) {
    gchar* buffer = nullptr;
    gsize size = 0;
    if (gdk_pixbuf_save_to_buffer(image, &buffer, &size, "png", nullptr,
                                  nullptr) &&
        buffer != nullptr && size > 0) {
      AddPicture(list, "schowek.png", reinterpret_cast<const guint8*>(buffer),
                 size);
    }
    g_free(buffer);
    g_object_unref(image);
  }
  return list;
}

void OnCall(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  if (std::strcmp(fl_method_call_get_name(call), "read") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  bool text_first = false;
  FlValue* args = fl_method_call_get_args(call);
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* value = fl_value_lookup_string(args, "textFirst");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) {
      text_first = fl_value_get_bool(value);
    }
  }
  g_autoptr(FlValue) items = ReadClipboard(text_first);
  fl_method_call_respond_success(call, items, nullptr);
}

void OnDragDataReceived(GtkWidget* widget, GdkDragContext* context, gint x,
                        gint y, GtkSelectionData* selection, guint info,
                        guint time, gpointer data) {
  gchar** uris = gtk_selection_data_get_uris(selection);
  const std::vector<std::string> paths = PathsFromUris(uris);
  g_strfreev(uris);
  // GTK_DEST_DEFAULT_DROP finishes the drag itself.
  if (paths.empty() || g_channel == nullptr) {
    return;
  }
  gint view_x = x;
  gint view_y = y;
  if (g_view != nullptr) {
    gtk_widget_translate_coordinates(widget, g_view, x, y, &view_x, &view_y);
  }
  g_autoptr(FlValue) args = fl_value_new_map();
  FlValue* list = fl_value_new_list();
  for (const std::string& path : paths) {
    fl_value_append_take(list, fl_value_new_string(path.c_str()));
  }
  fl_value_set_string_take(args, "paths", list);
  fl_value_set_string_take(args, "x", fl_value_new_float(view_x));
  fl_value_set_string_take(args, "y", fl_value_new_float(view_y));
  fl_method_channel_invoke_method(g_channel, "drop", args, nullptr, nullptr,
                                  nullptr);
}

}  // namespace

void zen_media_transfer_register(FlPluginRegistry* registry, GtkWidget* window,
                                 GtkWidget* view) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry,
                                                  "ZenMediaTransfer");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "zen/media_transfer", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, OnCall, nullptr,
                                            nullptr);
  g_view = view;
  static GtkTargetEntry targets[] = {
      {const_cast<gchar*>("text/uri-list"), 0, 0},
  };
  gtk_drag_dest_set(window, GTK_DEST_DEFAULT_ALL, targets, 1, GDK_ACTION_COPY);
  g_signal_connect(window, "drag-data-received",
                   G_CALLBACK(OnDragDataReceived), nullptr);
}
