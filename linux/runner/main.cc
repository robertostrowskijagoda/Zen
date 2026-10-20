#include <cstdlib>
#include <cstring>

#include "my_application.h"

// A test profile (--zen-profile=NAME or ZEN_PROFILE, lib/src/app/zen_instance.dart)
// runs as its own instance; every other launch joins the running one.
static gboolean is_test_profile(int argc, char** argv) {
  const char* variable = getenv("ZEN_PROFILE");
  if (variable != nullptr && variable[0] != '\0') {
    return TRUE;
  }
  for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], "--zen-profile=", strlen("--zen-profile=")) == 0) {
      return TRUE;
    }
  }
  return FALSE;
}

int main(int argc, char** argv) {
  g_autoptr(MyApplication) app = my_application_new(!is_test_profile(argc, argv));
  return g_application_run(G_APPLICATION(app), argc, argv);
}
