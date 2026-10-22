#ifndef RUNNER_PORTRAIT_WINDOW_H_
#define RUNNER_PORTRAIT_WINDOW_H_

#include <windows.h>

// Zen's window is always portrait: never wider than kMaxAspect of its
// height, whether the person drags an edge, maximizes, snaps it to half
// the screen or the app resizes it.
namespace portrait_window {

// Width / height at most.
constexpr double kMaxAspect = 0.8;

// WM_GETMINMAXINFO, after the plugins: a maximized window is a column as
// tall as the work area, centred on it.
void LimitMaximized(HWND hwnd, MINMAXINFO* info);

// WM_SIZING: keeps the dragged rectangle portrait (moves the edge being
// dragged, or the right one).
void ClampSizing(WPARAM edge, RECT* rect);

// WM_WINDOWPOSCHANGING: any other size change (snapping, the app, full
// screen) is narrowed around its centre.
void ClampPosition(HWND hwnd, WINDOWPOS* pos);

}  // namespace portrait_window

#endif  // RUNNER_PORTRAIT_WINDOW_H_
