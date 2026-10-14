package com.roj.zen

import androidx.core.content.FileProvider

/**
 * Serves the installer copy that "Podaj dalej" hands to the system share
 * sheet (res/xml/zen_share_paths.xml: the cache's shared_apk folder only).
 * A class of its own, so it never clashes in the merged manifest with a
 * plugin that declares the plain androidx FileProvider.
 */
class ZenFileProvider : FileProvider()
