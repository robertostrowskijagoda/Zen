#include "zen_portrait_window.h"

namespace {

// Width / height at most.
constexpr double kMaxAspect = 0.8;

int max_width_for(int height) {
  return static_cast<int>(height * kMaxAspect);
}

// Narrows a too wide window (after the event, not inside it).
gboolean narrow_later(gpointer data) {
  GtkWindow* window = GTK_WINDOW(data);
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window != nullptr) {
    const GdkWindowState state = gdk_window_get_state(gdk_window);
    if ((state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                  GDK_WINDOW_STATE_ICONIFIED)) == 0) {
      int width = 0;
      int height = 0;
      gtk_window_get_size(window, &width, &height);
      if (height > 0 && width > max_width_for(height)) {
        gtk_window_resize(window, max_width_for(height), height);
      }
    }
  }
  g_object_unref(window);
  return G_SOURCE_REMOVE;
}

// Turns a maximized or full-screen window into a tall centred column.
gboolean column_later(gpointer data) {
  GtkWindow* window = GTK_WINDOW(data);
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window != nullptr) {
    const GdkWindowState state = gdk_window_get_state(gdk_window);
    if ((state & GDK_WINDOW_STATE_FULLSCREEN) != 0) {
      gtk_window_unfullscreen(window);
    }
    if ((state & GDK_WINDOW_STATE_MAXIMIZED) != 0) {
      gtk_window_unmaximize(window);
    }
    GdkDisplay* display = gdk_window_get_display(gdk_window);
    GdkMonitor* monitor =
        display == nullptr
            ? nullptr
            : gdk_display_get_monitor_at_window(display, gdk_window);
    if (monitor != nullptr) {
      GdkRectangle area;
      gdk_monitor_get_workarea(monitor, &area);
      // Room for the title bar and the window's shadow.
      const int height = area.height * 92 / 100;
      int width = max_width_for(height);
      if (width > area.width) {
        width = area.width;
      }
      gtk_window_resize(window, width, height);
      gtk_window_move(window, area.x + (area.width - width) / 2,
                      area.y + (area.height - height) / 2);
    }
  }
  g_object_unref(window);
  return G_SOURCE_REMOVE;
}

gboolean on_configure(GtkWidget* widget, GdkEventConfigure* event,
                      gpointer) {
  if (event->height > 0 && event->width > max_width_for(event->height)) {
    g_idle_add(narrow_later, g_object_ref(widget));
  }
  return FALSE;
}

gboolean on_window_state(GtkWidget* widget, GdkEventWindowState* event,
                         gpointer) {
  const GdkWindowState entered = static_cast<GdkWindowState>(
      event->changed_mask & event->new_window_state);
  if ((entered & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) !=
      0) {
    g_idle_add(column_later, g_object_ref(widget));
  }
  return FALSE;
}

}  // namespace

void zen_portrait_window_attach(GtkWindow* window) {
  g_signal_connect(window, "configure-event", G_CALLBACK(on_configure),
                   nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(on_window_state),
                   nullptr);
}
