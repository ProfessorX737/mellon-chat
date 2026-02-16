/// Model catalog data models for the Mellon Chat model picker.
///
/// These represent the server's /model response catalog.
/// Each mode variant (e.g., sonnet-4.5-plan) is a separate model entry —
/// the client has no concept of "modes", just providers and models.
library;

/// The full model catalog returned inside org.mellonchat.channel_data
class ModelCatalog {
  final ModelSelection current;
  final List<ProviderEntry> catalog;
  final DateTime fetchedAt;

  /// Global per-room cache of model catalogs.
  /// Keyed by room ID, persists across chat navigations within the session.
  static final Map<String, ModelCatalog> _roomCache = {};

  /// Get cached catalog for a room, or null if not cached / stale.
  static ModelCatalog? getForRoom(String roomId) {
    final cached = _roomCache[roomId];
    if (cached == null) return null;
    if (cached.isStale) {
      _roomCache.remove(roomId);
      return null;
    }
    return cached;
  }

  /// Cache a catalog for a room.
  static void cacheForRoom(String roomId, ModelCatalog catalog) {
    _roomCache[roomId] = catalog;
  }

  /// Set of room IDs where we've already attempted auto-fetch this session,
  /// so we don't send repeated /model commands.
  static final Set<String> _autoFetchAttempted = {};

  /// Whether auto-fetch has been attempted for this room.
  static bool wasAutoFetchAttempted(String roomId) =>
      _autoFetchAttempted.contains(roomId);

  /// Mark auto-fetch as attempted for this room.
  static void markAutoFetchAttempted(String roomId) =>
      _autoFetchAttempted.add(roomId);

  ModelCatalog({
    required this.current,
    required this.catalog,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  factory ModelCatalog.fromJson(Map<String, dynamic> json) {
    return ModelCatalog(
      current: ModelSelection.fromJson(
        json['current'] as Map<String, dynamic>,
      ),
      catalog: (json['catalog'] as List<dynamic>)
          .map((e) => ProviderEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Whether cached data is older than 5 minutes
  bool get isStale => DateTime.now().difference(fetchedAt).inMinutes > 5;

  /// Find a provider by name, returns null if not found
  ProviderEntry? findProvider(String provider) {
    for (final entry in catalog) {
      if (entry.provider == provider) return entry;
    }
    return null;
  }
}

/// The currently active model selection
class ModelSelection {
  final String provider;
  final String model;

  ModelSelection({required this.provider, required this.model});

  factory ModelSelection.fromJson(Map<String, dynamic> json) {
    return ModelSelection(
      provider: json['provider'] as String,
      model: json['model'] as String,
    );
  }

  /// Full model ID as sent to the server: "provider/model"
  String get fullModelId => '$provider/$model';

  /// Display label: "provider / model"
  String get displayLabel => '$provider / $model';
}

/// A provider and its list of available models
class ProviderEntry {
  final String provider;
  final List<CatalogModel> models;

  ProviderEntry({required this.provider, required this.models});

  factory ProviderEntry.fromJson(Map<String, dynamic> json) {
    return ProviderEntry(
      provider: json['provider'] as String,
      models: (json['models'] as List<dynamic>)
          .map((e) => CatalogModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// A single model within a provider's catalog
class CatalogModel {
  final String id;
  final String name;

  CatalogModel({required this.id, required this.name});

  factory CatalogModel.fromJson(Map<String, dynamic> json) {
    return CatalogModel(
      id: json['id'] as String,
      name: json['name'] as String,
    );
  }
}
