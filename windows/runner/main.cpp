#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Hardening that leaves Flutter's AOT code, the plugins and the Go bridge
// alone: the heap ends the process on corruption instead of running on,
// no DLL is looked for in the current directory, and none is loaded from a
// network share or from a low-integrity file (a planted library). Policies
// that could stop the app (no dynamic code, Microsoft-signed images only,
// strict handle checks, no extension points) are left off: the Dart VM,
// the bridge or accessibility tools may need what they forbid.
void HardenProcess() {
  ::HeapSetInformation(nullptr, HeapEnableTerminationOnCorruption, nullptr,
                       0);
  ::SetDllDirectoryW(L"");
  using SetPolicy = BOOL(WINAPI*)(PROCESS_MITIGATION_POLICY, PVOID, SIZE_T);
  HMODULE kernel = ::GetModuleHandleW(L"kernel32.dll");
  auto set_policy = kernel == nullptr
                        ? nullptr
                        : reinterpret_cast<SetPolicy>(::GetProcAddress(
                              kernel, "SetProcessMitigationPolicy"));
  if (set_policy == nullptr) {
    return;
  }
  PROCESS_MITIGATION_IMAGE_LOAD_POLICY images = {};
  images.NoRemoteImages = 1;
  images.NoLowMandatoryLabelImages = 1;
  set_policy(ProcessImageLoadPolicy, &images, sizeof(images));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HardenProcess();
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Disable experimental Impeller on Windows to prevent black screen rendering issues.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(430, 880);
  if (!window.Create(L"Zen", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::ExitProcess(EXIT_SUCCESS);
}
