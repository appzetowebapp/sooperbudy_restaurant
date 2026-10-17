import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/config/theme_config.dart';
import 'package:webview_master_app/screens/splash_screen.dart';
import 'package:webview_master_app/utils/prefs_util.dart';
import 'package:webview_master_app/utils/fcm_background_handler.dart';
import 'package:webview_master_app/screens/webview_screen.dart';
import 'package:webview_master_app/utils/notification_service.dart';
import 'package:webview_master_app/utils/background_service_util.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

/// Main entry point of the application
void main() async {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  try {
    await Firebase.initializeApp();
    debugPrint('✅ Firebase initialized');

    // Register background message handler (for notifications when app is in background/terminated)
    // Foreground notifications are handled by NotificationService.onMessage listener
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    debugPrint('✅ Background message handler registered');
    debugPrint('📱 Notification setup: Both foreground and background notifications enabled');
  } catch (e) {
    debugPrint('❌ Error initializing Firebase: $e');
    debugPrint('⚠️ Make sure google-services.json is added to android/app/');
  }

  // Initialize SharedPreferences
  await PrefsUtil.init();

  // Initialize Notification Service early
  // This sets up foreground notification handler (FirebaseMessaging.onMessage)
  // and handles all notification display logic
  try {
    final notificationService = NotificationService();
    await notificationService.initialize();
    debugPrint('✅ Notification service initialized in main');
    
    // Request notification permission immediately on app startup
    await notificationService.requestPermission();
    debugPrint('📱 Notification permission requested on startup');
    
    debugPrint('📱 Foreground notifications: Enabled via NotificationService');
  } catch (e) {
    debugPrint('❌ Error initializing notification service in main: $e');
  }

  // Initialize Background Service
  try {
    await BackgroundServiceUtil.initializeService();
    
    // Start if user has it enabled in preferences OR user is logged in
    final isLoggedIn = PrefsUtil.getAccessToken() != null;
    if (PrefsUtil.isOverlayEnabled() || isLoggedIn) {
      await BackgroundServiceUtil.start();
      debugPrint('✅ Background service initialized and started (Overlay enabled: ${PrefsUtil.isOverlayEnabled()}, Is Logged In: $isLoggedIn)');
    } else {
      debugPrint('ℹ️ Background service initialized but NOT started (Overlay disabled and User logged out)');
    }
  } catch (e) {
    debugPrint('❌ Error initializing background service: $e');
  }

  // Initial system UI overlay style (will be updated based on theme in each screen)
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: AppConfig.statusBarColorLight,
      statusBarIconBrightness: AppConfig.statusBarIconBrightnessLight,
      systemNavigationBarColor: AppConfig.navigationBarColorLight,
      systemNavigationBarIconBrightness:
          AppConfig.navigationBarIconBrightnessLight,
    ),
  );

  runApp(const MyApp());
}

/// Root widget of the application
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  // Default to system theme mode
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadThemeMode();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('📱 App resumed: Keeping order ringtone active (requires explicit user action to stop)');
      // NotificationService().stopOrderAlertSound(); // Stopped only on Accept/Reject/Cancel/Expire
    } else if (state == AppLifecycleState.detached) {
      // App is being terminated (e.g. swiped away from Recent Apps).
      // Stop the ringtone immediately and release all audio resources.
      debugPrint('📱 App detached (swiped from recents): Stopping ringtone and releasing resources.');
      _stopAllRingtoneResources();
    }
  }

  /// Stop ringtone from all sources when the app is terminated.
  /// Covers: background service AudioPlayer, FCM fallback isolate AudioPlayer,
  /// and cancels all active notifications.
  void _stopAllRingtoneResources() {
    try {
      // 1. Stop via background service
      final service = FlutterBackgroundService();
      service.invoke('stopRingtone', {'reason': 'App removed from recents'});
      debugPrint('📱 Sent stopRingtone to background service.');

      // 2. Stop the FCM fallback isolate player via inter-isolate port
      final bgPort = IsolateNameServer.lookupPortByName('bg_fcm_audio_port');
      if (bgPort != null) {
        bgPort.send('stop');
        debugPrint('📱 Sent stop to bg_fcm_audio_port.');
      }

      // 3. Cancel all system notifications
      NotificationService().cancelAllNotifications();
      debugPrint('📱 Cancelled all notifications.');
    } catch (e) {
      debugPrint('⚠️ Error stopping ringtone on app detach: $e');
    }
  }

  /// Load saved theme mode from preferences
  void _loadThemeMode() {
    final themeModeInt = PrefsUtil.getThemeMode();
    setState(() {
      _themeMode = ThemeMode.values[themeModeInt];
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: AppConfig.appName,

      // Theme configuration
      theme: ThemeConfig.lightTheme,
      darkTheme: ThemeConfig.darkTheme,
      themeMode: _themeMode,

      // Home screen
      home: const SplashScreen(),

      // Builder for additional configuration
      builder: (context, child) {
        return child ?? const SizedBox.shrink();
      },
    );
  }
}