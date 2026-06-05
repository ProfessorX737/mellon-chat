import 'package:flutter/material.dart';

import 'package:fluffychat/ai_stream/model_catalog.dart';

/// Show the model picker as a modal bottom sheet.
///
/// Returns the selected model ID string (e.g., "openai/gpt-5.5")
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
      maxHeight: MediaQuery.sizeOf(context).height * 0.6,
    ),
    builder: (context) => _ModelPickerPanel(catalog: catalog),
  );
}

class _ModelOption {
  final String provider;
  final CatalogModel? model;
  final String command;

  _ModelOption({required this.provider, required this.command, this.model});

  bool get hasFriendlyModelName {
    final model = this.model;
    return model != null && model.name.trim() != model.id;
  }
}

class _ModelPickerPanel extends StatelessWidget {
  final ModelCatalog catalog;

  const _ModelPickerPanel({required this.catalog});

  List<_ModelOption> get _options {
    return [
      _optionForProvider(provider: 'claude', alias: 'Claude'),
      _optionForProvider(provider: 'openai', alias: 'OpenAI'),
    ];
  }

  _ModelOption _optionForProvider({
    required String provider,
    required String alias,
  }) {
    final entry = catalog.catalog.where((entry) {
      if (provider == 'claude') {
        return entry.provider == 'claude' || entry.provider == 'anthropic';
      }
      return entry.provider == provider;
    }).firstOrNull;
    final model = entry?.models.length == 1 ? entry!.models.first : null;
    return _ModelOption(
      provider: provider,
      model: model,
      command: model == null ? alias : '${entry!.provider}/${model.id}',
    );
  }

  IconData _providerIcon(String provider) {
    switch (provider.trim().toLowerCase()) {
      case 'openai':
        return Icons.auto_awesome_outlined;
      case 'claude':
      case 'anthropic':
        return Icons.smart_toy_outlined;
      default:
        return Icons.hub_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = _options;
    final currentId = catalog.current.fullModelId;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Choose Model', style: theme.textTheme.titleMedium),
        ),
        const Divider(height: 1),
        Flexible(
          child: options.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No models are available.',
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: options.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final option = options[index];
                    final isSelected =
                        currentId == option.command ||
                        formatProviderLabel(catalog.current.provider) ==
                            formatProviderLabel(option.provider);
                    return ListTile(
                      selected: isSelected,
                      selectedTileColor: theme.colorScheme.primaryContainer,
                      leading: Icon(
                        _providerIcon(option.provider),
                        color: isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(formatProviderLabel(option.provider)),
                      subtitle: Text(
                        option.hasFriendlyModelName
                            ? '${option.model!.name}\n${option.command}'
                            : 'Latest configured ${formatProviderLabel(option.provider)} model',
                        maxLines: option.hasFriendlyModelName ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      isThreeLine: option.hasFriendlyModelName,
                      trailing: isSelected
                          ? Icon(
                              Icons.check,
                              size: 20,
                              color: theme.colorScheme.primary,
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(option.command),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
