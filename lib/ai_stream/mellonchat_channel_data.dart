/// Parser for mellonchat channel data embedded in Matrix message events.
///
/// The OpenClaw server embeds structured data under `org.mellonchat.channel_data`
/// in the Matrix event content when responding to /model commands.
library;

import 'model_catalog.dart';

class MellonchatChannelData {
  final String type;
  final ModelCatalog? modelCatalog;

  MellonchatChannelData({required this.type, this.modelCatalog});

  /// Try to extract mellonchat channel data from a Matrix event content map.
  ///
  /// Looks for `org.mellonchat.channel_data` key (matching the existing
  /// `org.mellonchat.ai_stream` convention).
  ///
  /// Returns null if no mellonchat channel data is present.
  static MellonchatChannelData? fromEventContent(
    Map<String, dynamic> content,
  ) {
    final mellonchat =
        content['org.mellonchat.channel_data'] as Map<String, dynamic>?;
    if (mellonchat == null) return null;

    final type = mellonchat['type'] as String?;
    if (type == null) return null;

    if (type == 'model_picker') {
      try {
        return MellonchatChannelData(
          type: type,
          modelCatalog: ModelCatalog.fromJson(mellonchat),
        );
      } catch (_) {
        return null;
      }
    }

    return MellonchatChannelData(type: type);
  }

  bool get isModelPicker => type == 'model_picker';
}
