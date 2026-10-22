#ifndef RUNNER_ZEN_PORTRAIT_WINDOW_H_
#define RUNNER_ZEN_PORTRAIT_WINDOW_H_

#include <gtk/gtk.h>

// Keeps Zen's window portrait: never wider than 0.8 of its height. A
// maximized or full-screen window becomes the tallest such column on its
// screen instead.
void zen_portrait_window_attach(GtkWindow* window);

#endif  // RUNNER_ZEN_PORTRAIT_WINDOW_H_
