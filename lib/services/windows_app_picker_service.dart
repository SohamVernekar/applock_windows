import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class WindowsAppPickerService {
  Future<String?> pickExecutablePath() async {
    final dialog = calloc<OPENFILENAME>();
    final fileBuffer = calloc<Uint16>(MAX_PATH).cast<Utf16>();
    final filter = _buildFilter(
      'Applications (*.exe)',
      '*.exe',
      'All Files (*.*)',
      '*.*',
    );
    final title = 'Choose an application to protect'.toNativeUtf16();

    try {
      dialog.ref.lStructSize = sizeOf<OPENFILENAME>();
      dialog.ref.lpstrFilter = filter;
      dialog.ref.lpstrFile = fileBuffer;
      dialog.ref.nMaxFile = MAX_PATH;
      dialog.ref.lpstrTitle = title;
      dialog.ref.Flags =
          OFN_EXPLORER |
          OFN_FILEMUSTEXIST |
          OFN_PATHMUSTEXIST |
          OFN_HIDEREADONLY;

      final result = GetOpenFileName(dialog);
      if (result == 0) {
        return null;
      }

      final path = fileBuffer.toDartString();
      return path.isEmpty ? null : path;
    } finally {
      calloc.free(dialog);
      calloc.free(fileBuffer);
      calloc.free(filter);
      calloc.free(title);
    }
  }

  Pointer<Utf16> _buildFilter(
    String labelOne,
    String patternOne,
    String labelTwo,
    String patternTwo,
  ) {
    final raw =
        '$labelOne\u0000$patternOne\u0000$labelTwo\u0000$patternTwo\u0000\u0000';
    return raw.toNativeUtf16();
  }
}
