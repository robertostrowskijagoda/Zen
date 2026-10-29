/// The pebble screens' parts made elsewhere: the stone renderer
/// (`PebbleView`), the editor (`PebbleEditorScreen.open`) and the sticker
/// designer's pebble kind (`openPebbleSticker`). Stand-ins until they are
/// there; each is swapped by changing its line here (the sticker:
/// `export '../qr_sticker/presentation/sticker_designer_screen.dart'
/// show openPebbleSticker;`).
library;

export 'pebble_sticker_placeholder.dart';
export 'presentation/pebble_editor_placeholder.dart';
export 'render/pebble_view_placeholder.dart';
