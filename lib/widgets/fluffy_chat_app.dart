import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluffychat/config/routes.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/dev_log_sink.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
import '../utils/custom_scroll_behaviour.dart';
import 'matrix.dart';

class FluffyChatApp extends StatelessWidget {
  final Widget? testWidget;
  final List<Client> clients;
  final String? pincode;
  final SharedPreferences store;

  const FluffyChatApp({
    super.key,
    this.testWidget,
    required this.clients,
    required this.store,
    this.pincode,
  });

  /// getInitialLink may rereturn the value multiple times if this view is
  /// opened multiple times for example if the user logs out after they logged
  /// in with qr code or magic link.
  static bool gotInitialLink = false;

  // Router must be outside of build method so that hot reload does not reset
  // the current path.
  static final GoRouter router = GoRouter(
    routes: AppRoutes.routes,
    debugLogDiagnostics: true,
    errorBuilder: (context, state) {
      DevLogSink.startup('mellon.router.error_builder', {
        'uri': state.uri.toString(),
        'uri_path': state.uri.path,
        'uri_query': state.uri.query,
        'matched_location': state.matchedLocation,
        'full_path': state.fullPath,
        'path': state.path,
        'error': state.error?.toString(),
        'base_path': Uri.base.path,
        'base_query': Uri.base.query,
        'base_fragment': Uri.base.fragment,
      });
      return Scaffold(
        body: Center(
          child: Text(state.error?.toString() ?? 'Unable to load route'),
        ),
      );
    },
  );
  static bool _loggedFirstBuild = false;
  static int _materialConfigLogCount = 0;
  static int _materialBuilderLogCount = 0;

  @override
  Widget build(BuildContext context) {
    if (!_loggedFirstBuild) {
      _loggedFirstBuild = true;
      DevLogSink.startup('mellon.startup.app_build', {
        'uri_path': Uri.base.path,
        'uri_query': Uri.base.query,
        'uri_fragment': Uri.base.fragment,
        'router_uri': router.routeInformationProvider.value.uri.toString(),
        'client_count': clients.length,
        'logged_client_count': clients
            .where((client) => client.isLogged())
            .length,
        'has_pincode': pincode != null,
      });
    }
    return ThemeBuilder(
      builder: (context, themeMode, primaryColor) {
        final shouldLogConfig = _materialConfigLogCount < 5;
        if (shouldLogConfig) {
          _materialConfigLogCount++;
          DevLogSink.startup('mellon.startup.material_config_start', {
            'build_count': _materialConfigLogCount,
            'theme_mode': themeMode.name,
            'has_primary_color': primaryColor != null,
            'uri_path': Uri.base.path,
            'uri_query': Uri.base.query,
            'uri_fragment': Uri.base.fragment,
          });
        }

        try {
          final lightTheme = FluffyThemes.buildTheme(
            context,
            Brightness.light,
            primaryColor,
          );
          final darkTheme = FluffyThemes.buildTheme(
            context,
            Brightness.dark,
            primaryColor,
          );

          if (shouldLogConfig) {
            DevLogSink.startup('mellon.startup.material_config_done', {
              'build_count': _materialConfigLogCount,
              'theme_mode': themeMode.name,
              'has_primary_color': primaryColor != null,
            });
          }

          return MaterialApp.router(
            title: AppSettings.applicationName.value,
            themeMode: themeMode,
            theme: lightTheme,
            darkTheme: darkTheme,
            scrollBehavior: CustomScrollBehavior(),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            routerConfig: router,
            builder: (context, child) {
              if (_materialBuilderLogCount < 5) {
                _materialBuilderLogCount++;
                DevLogSink.startup('mellon.startup.material_builder', {
                  'build_count': _materialBuilderLogCount,
                  'has_child': child != null,
                  'child_type': child?.runtimeType.toString(),
                  'uri_path': Uri.base.path,
                  'uri_query': Uri.base.query,
                  'uri_fragment': Uri.base.fragment,
                  'router_uri': router.routeInformationProvider.value.uri
                      .toString(),
                  'client_count': clients.length,
                  'logged_client_count': clients
                      .where((client) => client.isLogged())
                      .length,
                });
              }
              return AppLockWidget(
                pincode: pincode,
                clients: clients,
                // Need a navigator above the Matrix widget for
                // displaying dialogs
                child: Matrix(
                  clients: clients,
                  store: store,
                  child: testWidget ?? child,
                ),
              );
            },
          );
        } catch (error, stack) {
          DevLogSink.startup('mellon.startup.material_config_error', {
            'build_count': _materialConfigLogCount,
            'theme_mode': themeMode.name,
            'has_primary_color': primaryColor != null,
            'error': error.toString(),
            'stack': stack.toString().split('\n').take(12).join('\n'),
          });
          rethrow;
        }
      },
    );
  }
}
