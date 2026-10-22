#include "portrait_window.h"

namespace portrait_window {

namespace {

LONG MaxWidthFor(LONG height) {
  return static_cast<LONG>(height * kMaxAspect);
}

}  // namespace

void LimitMaximized(HWND hwnd, MINMAXINFO* info) {
  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi;
  mi.cbSize = sizeof(mi);
  if (monitor == nullptr || !GetMonitorInfo(monitor, &mi)) {
    return;
  }
  const RECT work = mi.rcWork;
  const LONG work_width = work.right - work.left;
  const LONG height = work.bottom - work.top;
  LONG width = MaxWidthFor(height);
  if (width > work_width) {
    width = work_width;
  }
  info->ptMaxSize.x = width;
  info->ptMaxSize.y = height;
  // Relative to the monitor, as Windows expects.
  info->ptMaxPosition.x =
      work.left - mi.rcMonitor.left + (work_width - width) / 2;
  info->ptMaxPosition.y = work.top - mi.rcMonitor.top;
  if (info->ptMaxTrackSize.x < width) {
    info->ptMaxTrackSize.x = width;
  }
  if (info->ptMaxTrackSize.y < height) {
    info->ptMaxTrackSize.y = height;
  }
}

void ClampSizing(WPARAM edge, RECT* rect) {
  const LONG height = rect->bottom - rect->top;
  const LONG width = rect->right - rect->left;
  const LONG max_width = MaxWidthFor(height);
  if (width <= max_width) {
    return;
  }
  switch (edge) {
    case WMSZ_LEFT:
    case WMSZ_TOPLEFT:
    case WMSZ_BOTTOMLEFT:
      rect->left = rect->right - max_width;
      break;
    default:
      rect->right = rect->left + max_width;
      break;
  }
}

void ClampPosition(HWND hwnd, WINDOWPOS* pos) {
  if ((pos->flags & SWP_NOSIZE) != 0 || IsIconic(hwnd) || IsZoomed(hwnd) ||
      pos->cx <= 0 || pos->cy <= 0) {
    return;
  }
  const LONG max_width = MaxWidthFor(pos->cy);
  if (pos->cx <= max_width) {
    return;
  }
  if ((pos->flags & SWP_NOMOVE) == 0) {
    pos->x += (pos->cx - max_width) / 2;
  }
  pos->cx = max_width;
}

}  // namespace portrait_window
