import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:collection/collection.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/dev_log_sink.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'config/setting_keys.dart';
import 'utils/background_push.dart';
import 'widgets/fluffy_chat_app.dart';

ReceivePort? mainIsolateReceivePort;

void main() async {
  final startupWatch = Stopwatch()..start();
  void logStartup(String event, [Map<String, Object?> fields = const {}]) {
    DevLogSink.startup(event, {
      'elapsed_ms': startupWatch.elapsedMilliseconds,
      'is_web': PlatformInfos.isWeb,
      'is_mobile': PlatformInfos.isMobile,
      ...fields,
    });
  }

  try {
    logStartup('mellon.startup.main_enter');
    logStartup('mellon.startup.build_info');

    if (PlatformInfos.isAndroid) {
      final port = mainIsolateReceivePort = ReceivePort();
      IsolateNameServer.removePortNameMapping(AppConfig.mainIsolatePortName);
      IsolateNameServer.registerPortWithName(
        port.sendPort,
        AppConfig.mainIsolatePortName,
      );
      logStartup('mellon.startup.android_push_wait_start');
      await waitForPushIsolateDone();
      logStartup('mellon.startup.android_push_wait_done');
    }

    // Our background push shared isolate accesses flutter-internal things very early in the startup proccess
    // To make sure that the parts of flutter needed are started up already, we need to ensure that the
    // widget bindings are initialized already.
    WidgetsFlutterBinding.ensureInitialized();
    logStartup('mellon.startup.bindings_ready');
    final previousFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      logStartup('mellon.startup.flutter_error', {
        'error': details.exceptionAsString(),
        'stack': details.stack?.toString().split('\n').take(8).join('\n'),
      });
      previousFlutterOnError?.call(details);
    };
    final previousPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      logStartup('mellon.startup.platform_error', {
        'error': error.toString(),
        'stack': stack.toString().split('\n').take(8).join('\n'),
      });
      return previousPlatformOnError?.call(error, stack) ?? false;
    };
    DevLogSink.installMatrixLogForwarder();

    final store = await AppSettings.init();
    logStartup('mellon.startup.settings_ready');
    Logs().i('Welcome to ${AppSettings.applicationName.value} <3');

    await vod.init(wasmPath: './assets/assets/vodozemac/');
    logStartup('mellon.startup.crypto_ready');

    Logs().nativeColors = !PlatformInfos.isIOS;
    final clients = await ClientManager.getClients(store: store);
    logStartup('mellon.startup.clients_ready', {
      'client_count': clients.length,
      'has_active_client': clients.isNotEmpty,
    });

    // If the app starts in detached mode, we assume that it is in
    // background fetch mode for processing push notifications. This is
    // currently only supported on Android.
    if (PlatformInfos.isAndroid &&
        AppLifecycleState.detached == WidgetsBinding.instance.lifecycleState) {
      // Do not send online presences when app is in background fetch mode.
      for (final client in clients) {
        client.backgroundSync = false;
        client.syncPresence = PresenceType.offline;
      }

      // In the background fetch mode we do not want to waste ressources with
      // starting the Flutter engine but process incoming push notifications.
      BackgroundPush.clientOnly(clients.first);
      // To start the flutter engine afterwards we add an custom observer.
      WidgetsBinding.instance.addObserver(AppStarter(clients, store));
      logStartup('mellon.startup.background_fetch_mode');
      Logs().i(
        '${AppSettings.applicationName.value} started in background-fetch mode. No GUI will be created unless the app is no longer detached.',
      );
      return;
    }

    // Started in foreground mode.
    logStartup('mellon.startup.foreground_mode');
    Logs().i(
      '${AppSettings.applicationName.value} started in foreground mode. Rendering GUI...',
    );
    await startGui(clients, store);
  } catch (e, s) {
    logStartup('mellon.startup.main_error', {
      'error': e.toString(),
      'stack': s.toString().split('\n').take(8).join('\n'),
    });
    rethrow;
  }
}

/// Fetch the pincode for the applock and start the flutter engine.
Future<void> startGui(List<Client> clients, SharedPreferences store) async {
  final startupWatch = Stopwatch()..start();
  void logStartup(String event, [Map<String, Object?> fields = const {}]) {
    DevLogSink.startup(event, {
      'elapsed_ms': startupWatch.elapsedMilliseconds,
      'client_count': clients.length,
      ...fields,
    });
  }

  logStartup('mellon.startup.gui_enter');

  // Fetch the pin for the applock if existing for mobile applications.
  String? pin;
  if (PlatformInfos.isMobile) {
    try {
      logStartup('mellon.startup.gui_pin_read_start');
      pin = await const FlutterSecureStorage().read(
        key: 'chat.fluffy.app_lock',
      );
      logStartup('mellon.startup.gui_pin_read_done', {'has_pin': pin != null});
    } catch (e, s) {
      logStartup('mellon.startup.gui_pin_read_error', {'error': e.toString()});
      Logs().d('Unable to read PIN from Secure storage', e, s);
    }
  }

  // Preload first client
  final firstClient = clients.firstOrNull;
  logStartup('mellon.startup.gui_preload_start', {
    'has_first_client': firstClient != null,
  });
  await firstClient?.roomsLoading;
  logStartup('mellon.startup.gui_rooms_ready');
  await firstClient?.accountDataLoading;
  logStartup('mellon.startup.gui_account_data_ready');

  logStartup('mellon.startup.run_app');
  runApp(FluffyChatApp(clients: clients, pincode: pin, store: store));
}

/// Watches the lifecycle changes to start the application when it
/// is no longer detached.
class AppStarter with WidgetsBindingObserver {
  final List<Client> clients;
  final SharedPreferences store;
  bool guiStarted = false;

  AppStarter(this.clients, this.store);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (guiStarted) return;
    if (state == AppLifecycleState.detached) return;

    Logs().i(
      '${AppSettings.applicationName.value} switches from the detached background-fetch mode to ${state.name} mode. Rendering GUI...',
    );
    // Switching to foreground mode needs to reenable send online sync presence.
    for (final client in clients) {
      client.backgroundSync = true;
      client.syncPresence = PresenceType.online;
    }
    startGui(clients, store);
    // We must make sure that the GUI is only started once.
    guiStarted = true;
  }
}
