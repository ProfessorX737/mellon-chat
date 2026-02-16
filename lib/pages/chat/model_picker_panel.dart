import 'package:flutter/material.dart';

import 'package:fluffychat/ai_stream/model_catalog.dart';

/// Show the model picker as a modal bottom sheet.
///
/// Returns the selected model ID string (e.g., "cursor/sonnet-4.5-plan")
/// or null if the user cancelled.
Future<String?> showModelPickerPanel({
  required BuildContext context,
  required ModelCatalog catalog,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    clipBehavior: Clip.hardEdge,
    constraints: BoxConstraints(
      maxWidth: 512,
      maxHeight: MediaQuery.sizeOf(context).height * 0.75,
    ),
    builder: (context) => _ModelPickerPanel(catalog: catalog),
  );
}

/// Mode suffixes used by the cursor provider.
/// Base model = agent mode (no suffix), -plan = plan mode, -ask = ask mode.
const _modeSuffixes = ['-plan', '-ask'];
const _modeLabels = ['Agent', 'Plan', 'Ask'];

/// Represents a base model that can have multiple modes (agent/plan/ask).
class _GroupedModel {
  final String baseId;
  final String baseName;
  /// Map of mode label → full model id (e.g. "Agent" → "sonnet-4.5")
  final Map<String, String> modes;

  _GroupedModel({
    required this.baseId,
    required this.baseName,
    required this.modes,
  });
}

/// Group models by stripping -plan/-ask suffixes.
/// Returns grouped models if at least one base has multiple modes,
/// otherwise returns null (provider doesn't use modes).
List<_GroupedModel>? _groupModelsByMode(List<CatalogModel> models) {
  final modelIds = models.map((m) => m.id).toSet();

  // Detect: is there at least one model that has both base and a -plan/-ask variant?
  bool hasModes = false;
  for (final m in models) {
    if (_modeSuffixes.any((s) => m.id.endsWith(s))) {
      hasModes = true;
      break;
    }
  }
  if (!hasModes) return null;

  // Build grouped models
  final seen = <String>{};
  final grouped = <_GroupedModel>[];

  for (final m in models) {
    // Skip if this is a mode variant (will be grouped under its base)
    if (_modeSuffixes.any((s) => m.id.endsWith(s))) continue;
    if (seen.contains(m.id)) continue;
    seen.add(m.id);

    final baseId = m.id;
    // Clean up the display name: remove "(Agent)" suffix if present
    final baseName = m.name
        .replaceAll(RegExp(r'\s*\(Agent\)\s*$'), '')
        .replaceAll(RegExp(r'\s*\(Plan\)\s*$'), '')
        .replaceAll(RegExp(r'\s*\(Ask\)\s*$'), '')
        .trim();

    final modes = <String, String>{'Agent': baseId};

    // Check for -plan and -ask variants
    if (modelIds.contains('$baseId-plan')) {
      modes['Plan'] = '$baseId-plan';
    }
    if (modelIds.contains('$baseId-ask')) {
      modes['Ask'] = '$baseId-ask';
    }

    grouped.add(_GroupedModel(
      baseId: baseId,
      baseName: baseName,
      modes: modes,
    ));
  }

  return grouped;
}

/// Resolve the current mode from a model ID (e.g. "sonnet-4.5-plan" → "Plan")
String _resolveModeFromId(String modelId) {
  if (modelId.endsWith('-plan')) return 'Plan';
  if (modelId.endsWith('-ask')) return 'Ask';
  return 'Agent';
}

/// Resolve the base model ID from a model ID (strip -plan/-ask suffix)
String _resolveBaseFromId(String modelId) {
  for (final s in _modeSuffixes) {
    if (modelId.endsWith(s)) return modelId.substring(0, modelId.length - s.length);
  }
  return modelId;
}

class _ModelPickerPanel extends StatefulWidget {
  final ModelCatalog catalog;

  const _ModelPickerPanel({required this.catalog});

  @override
  State<_ModelPickerPanel> createState() => _ModelPickerPanelState();
}

class _ModelPickerPanelState extends State<_ModelPickerPanel> {
  late String _selectedProvider;
  late String _selectedBaseModel;
  late String _selectedMode; // "Agent", "Plan", or "Ask"

  @override
  void initState() {
    super.initState();
    _selectedProvider = widget.catalog.current.provider;
    _selectedBaseModel = _resolveBaseFromId(widget.catalog.current.model);
    _selectedMode = _resolveModeFromId(widget.catalog.current.model);
  }

  /// Models for the currently selected provider
  List<CatalogModel> get _currentModels {
    final provider = widget.catalog.findProvider(_selectedProvider);
    return provider?.models ?? [];
  }

  /// Grouped models (null if provider doesn't use modes)
  List<_GroupedModel>? get _groupedModels => _groupModelsByMode(_currentModels);

  /// Full model ID from current selection
  String get _resolvedModelId {
    final grouped = _groupedModels;
    if (grouped != null) {
      // Find the grouped model and resolve mode
      final group = grouped.where((g) => g.baseId == _selectedBaseModel).firstOrNull;
      if (group != null && group.modes.containsKey(_selectedMode)) {
        return group.modes[_selectedMode]!;
      }
      // Fallback: just use base
      return _selectedBaseModel;
    }
    return _selectedBaseModel;
  }

  String get _previewId => '$_selectedProvider/$_resolvedModelId';

  void _selectProvider(String provider) {
    setState(() {
      _selectedProvider = provider;
      final models = widget.catalog.findProvider(provider)?.models ?? [];
      if (models.isNotEmpty) {
        _selectedBaseModel = _resolveBaseFromId(models.first.id);
        _selectedMode = 'Agent';
      }
    });
  }

  void _selectBaseModel(String baseId) {
    setState(() => _selectedBaseModel = baseId);
  }

  void _selectMode(String mode) {
    setState(() => _selectedMode = mode);
  }

  void _confirm() {
    Navigator.of(context).pop(_previewId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = _groupedModels;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Header ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Model Selection', style: theme.textTheme.titleMedium),
        ),
        const Divider(height: 1),

        // ── Scrollable content ──
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Provider section
                Text('Provider', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: widget.catalog.catalog.length,
                    itemBuilder: (context, index) {
                      final entry = widget.catalog.catalog[index];
                      final isSelected = entry.provider == _selectedProvider;
                      return ListTile(
                        dense: true,
                        selected: isSelected,
                        selectedTileColor: theme.colorScheme.primaryContainer,
                        title: Text(entry.provider),
                        trailing: isSelected
                            ? Icon(Icons.check,
                                size: 18, color: theme.colorScheme.primary)
                            : null,
                        onTap: () => _selectProvider(entry.provider),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 16),

                // Model section — grouped or flat
                Text('Model', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                if (grouped != null)
                  _buildGroupedModelList(theme, grouped)
                else
                  _buildFlatModelList(theme),

                // Mode toggle (only when provider uses modes)
                if (grouped != null) ...[
                  const SizedBox(height: 16),
                  Text('Mode', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  _buildModeToggle(theme, grouped),
                ],

                const SizedBox(height: 16),

                // Preview
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _previewId,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Confirm button ──
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _confirm,
            child: const Text('Apply'),
          ),
        ),
      ],
    );
  }

  /// Flat model list (for providers without modes)
  Widget _buildFlatModelList(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _currentModels.length,
        itemBuilder: (context, index) {
          final model = _currentModels[index];
          final isSelected = model.id == _selectedBaseModel;
          return ListTile(
            dense: true,
            selected: isSelected,
            selectedTileColor: theme.colorScheme.primaryContainer,
            title: Text(model.name),
            subtitle: Text(
              model.id,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: isSelected
                ? Icon(Icons.check,
                    size: 18, color: theme.colorScheme.primary)
                : null,
            onTap: () => setState(() => _selectedBaseModel = model.id),
          );
        },
      ),
    );
  }

  /// Grouped model list (for providers with modes like cursor)
  Widget _buildGroupedModelList(ThemeData theme, List<_GroupedModel> grouped) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: grouped.length,
        itemBuilder: (context, index) {
          final group = grouped[index];
          final isSelected = group.baseId == _selectedBaseModel;
          return ListTile(
            dense: true,
            selected: isSelected,
            selectedTileColor: theme.colorScheme.primaryContainer,
            title: Text(group.baseName),
            subtitle: Text(
              group.baseId,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: isSelected
                ? Icon(Icons.check,
                    size: 18, color: theme.colorScheme.primary)
                : null,
            onTap: () => _selectBaseModel(group.baseId),
          );
        },
      ),
    );
  }

  /// Three-way toggle for Agent / Plan / Ask
  Widget _buildModeToggle(ThemeData theme, List<_GroupedModel> grouped) {
    final group = grouped.where((g) => g.baseId == _selectedBaseModel).firstOrNull;
    final availableModes = group?.modes.keys.toList() ?? _modeLabels;

    return SegmentedButton<String>(
      segments: availableModes.map((mode) {
        return ButtonSegment<String>(
          value: mode,
          label: Text(mode),
          icon: Icon(
            mode == 'Agent'
                ? Icons.smart_toy_outlined
                : mode == 'Plan'
                    ? Icons.architecture_outlined
                    : Icons.help_outline,
            size: 16,
          ),
        );
      }).toList(),
      selected: {_selectedMode},
      onSelectionChanged: (selected) {
        if (selected.isNotEmpty) _selectMode(selected.first);
      },
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
