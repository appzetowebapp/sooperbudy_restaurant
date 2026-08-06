import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:webview_master_app/services/api_service.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/utils/new_order_notification_util.dart';
import 'package:webview_master_app/utils/notification_payload_util.dart';
import 'package:webview_master_app/utils/prefs_util.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'dart:io' show Platform;
import 'dart:convert';

/// Notification Service - Handles system tray notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() => _instance;

  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  FirebaseMessaging? _firebaseMessaging;

  bool _isInitialized = false;
  bool _listenersRegistered = false;
  static const _platform =
      MethodChannel('com.buddyserviceappzeto.restaurant/geolocation');

  // Track shown notifications to prevent duplicates
  final Set<String> _shownNotificationIds = <String>{};
  final Map<String, DateTime> _notificationTimestamps = <String, DateTime>{};

  // Stream for notification taps
  final _tapController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onTap => _tapController.stream;

  // Cold-start tap: set when the app is launched by tapping a notification while killed.
  // The broadcast stream fires before WebViewScreen can subscribe, so we store the data
  // here so the screen can pull it after the WebView finishes loading.
  Map<String, dynamic>? _coldStartTapData;
  Map<String, dynamic>? get coldStartTapData => _coldStartTapData;
  void consumeColdStartTap() => _coldStartTapData = null;

  /// Strict evaluation logic to check for explicit new order criteria only
  static bool isNewOrderNotification(Map<String, dynamic> data) {
    final type = (data['type'] ??
            data['notification_type'] ??
            data['click_action'] ??
            data['event'] ??
            '')
        .toString()
        .toLowerCase()
        .trim();

    final title = (data['title'] ?? '').toString().toLowerCase().trim();
    final body = (data['body'] ?? '').toString().toLowerCase().trim();

    debugPrint(
        '🔔 Notification Check => type="$type", title="$title", body="$body"');

    // Reject immediate non-order patterns
    if (title.contains('rider arrived') || body.contains('rider arrived')) {
      return false;
    }

    // Text Keyword Fallback Match
    if (title.contains('new order') ||
        title.contains('order received') ||
        title.contains('naya order')) {
      return true;
    }

    // Strict Target Whitelist Filter Mapping
    const newOrderTypes = {
      'new_order',
      'new-order',
      'neworder',
      'create_order',
      'order_placed',
    };

    if (newOrderTypes.contains(type)) {
      return true;
    }

    return false;
  }

  /// Check if the notification payload represents a cancellation or expiration event
  static bool isCancelOrExpireNotification(Map<String, dynamic> data) {
    final type = (data['type'] ??
            data['notification_type'] ??
            data['click_action'] ??
            data['event'] ??
            '')
        .toString()
        .toLowerCase()
        .trim();
    final title = (data['title'] ?? '').toString().toLowerCase().trim();
    final body = (data['body'] ?? '').toString().toLowerCase().trim();

    final cancelKeywords = [
      'cancel',
      'expire',
      'timeout',
      'timed out',
      'reject',
      'decline'
    ];

    for (final kw in cancelKeywords) {
      if (type.contains(kw) || title.contains(kw) || body.contains(kw)) {
        return true;
      }
    }
    return false;
  }

  /// Initialize notification service
  Future<void> initialize({bool isBackground = false}) async {
    if (_isInitialized) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings(AppConfig.notificationIcon);

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    if (Platform.isAndroid && !isBackground) {
      final androidPlugin =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      try {
        await androidPlugin?.requestNotificationsPermission();
      } catch (e) {
        debugPrint('⚠️ Foreground permission request skipped: $e');
      }
    }

    await _createNotificationChannel();
    await _initializeFirebaseMessaging();

    _isInitialized = true;
    debugPrint(
        '✅ Notification service initialized (isBackground: $isBackground)');
  }

  /// Initialize Firebase Cloud Messaging Configuration
  Future<void> _initializeFirebaseMessaging() async {
    try {
      _firebaseMessaging = FirebaseMessaging.instance;

      if (Platform.isIOS) {
        NotificationSettings settings =
            await _firebaseMessaging!.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
        if (settings.authorizationStatus == AuthorizationStatus.authorized) {
          debugPrint('✅ Firebase notification permission granted (iOS)');
        }
      }

      String? token = await _firebaseMessaging!.getToken();
      if (token != null) {
        debugPrint('📱 FCM Token: $token');
      }

      _firebaseMessaging!.onTokenRefresh.listen((newToken) async {
        await saveFCMTokenToBackend(phone: PrefsUtil.getPhoneNumber());
      });

      if (Platform.isIOS) {
        await _firebaseMessaging!.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: false,
        );
      }

      // Guard: register listeners only once per isolate. FirebaseMessaging streams
      // are additive — calling .listen() twice creates a second subscription and
      // causes every incoming message to be processed twice (foreground duplicates).
      if (!_listenersRegistered) {
        FirebaseMessaging.onMessage.listen((RemoteMessage message) {
          _handleForegroundMessage(message);
        });

        FirebaseMessaging.instance
            .getInitialMessage()
            .then((RemoteMessage? message) {
          if (message != null) {
            // Merge notification fields into data so the order-modal trigger has full context.
            final merged = Map<String, dynamic>.from(message.data);
            if (message.notification != null) {
              merged['title'] ??= message.notification!.title;
              merged['body'] ??= message.notification!.body;
            }
            // Store for cold-start consumption — the broadcast tap event fires before
            // WebViewScreen subscribes, so the screen reads this after the WebView loads.
            _coldStartTapData = merged;
            _handleNotificationTap(merged);
          }
        });

        FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
          _handleNotificationTap(message.data);
        });

        _listenersRegistered = true;
      }
    } catch (e) {
      debugPrint('❌ Error initializing Firebase Messaging: $e');
    }
  }

  /// Process foreground notifications systematically using precise validation filters
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    if (PrefsUtil.getAccessToken() == null) {
      debugPrint(
          '⚠️ Foreground FCM message received while logged out. Ignoring.');
      return;
    }

    RemoteNotification? notification = message.notification;
    Map<String, dynamic> data = Map<String, dynamic>.from(message.data);

    if (notification != null) {
      if (!data.containsKey('title') || data['title'] == null) {
        data['title'] = notification.title;
      }
      if (!data.containsKey('body') || data['body'] == null) {
        data['body'] = notification.body;
      }
    }

    String notificationId = message.messageId ?? '';
    // When messageId is absent, derive a stable key from the payload content so
    // rapid re-deliveries of the same message are caught by the dedup set.
    // Using a timestamp here would always produce a fresh key and defeat dedup.
    final String uniqueId = notificationId.isNotEmpty
        ? notificationId
        : '${data['type'] ?? ''}_${data['orderId'] ?? data['order_id'] ?? ''}_'
            '${notification?.title ?? data['title'] ?? ''}_'
            '${notification?.body ?? data['body'] ?? ''}';

    _cleanOldNotificationIds();

    if (_shownNotificationIds.contains(uniqueId)) return;

    final type = (data['type'] ??
            data['notification_type'] ??
            data['click_action'] ??
            data['event'] ??
            '')
        .toString()
        .toLowerCase()
        .trim();

    debugPrint('Notification Type = $type');

    if (type == 'new_order') {
      final orderId =
          data['orderId'] ?? data['order_id'] ?? data['id'] ?? 'unknown';
      debugPrint(
          '[RINGTONE_DEBUG] new_order received (Foreground). Order ID: $orderId');
    } else if (type == 'order_status_update') {
      debugPrint(
          '[RINGTONE_DEBUG] order_status_update received. Stopping ringtone. Reason: ORDER_STATUS_UPDATE');
      await stopOrderAlertSound(reason: 'ORDER_STATUS_UPDATE');
    } else if (isCancelOrExpireNotification(data) ||
        type == 'order_accepted' ||
        type == 'order_rejected' ||
        type == 'order_cancelled' ||
        type == 'order_expired') {
      final orderId =
          data['orderId'] ?? data['order_id'] ?? data['id'] ?? 'unknown';
      debugPrint(
          '[RINGTONE_DEBUG] Order cancelled/expired/rejected FCM received (Foreground). Order ID: $orderId, type: $type');
      debugPrint(
          '[RINGTONE_DEBUG] Stopping ringtone. Reason: ORDER_CANCELLED ($type)');
      await stopOrderAlertSound(reason: 'ORDER_CANCELLED ($type)');
    }

    if (isNewOrderNotification(data)) {
      final orderId =
          data['orderId'] ?? data['order_id'] ?? data['id'] ?? 'unknown';
      final orderTitle =
          notification?.title ?? data['title']?.toString() ?? 'New Order';
      final orderBody = notification?.body ??
          data['body']?.toString() ??
          'You have a new delivery order';
      debugPrint('[RINGTONE_DEBUG] new_order confirmed. Order ID: $orderId');

      await showOrderNotification(
        title: orderTitle,
        body: orderBody,
        payload: jsonEncode(data),
        notificationId: uniqueId,
        orderData: data,
      );

      if (type == 'new_order') {
        final orderId2 =
            data['orderId'] ?? data['order_id'] ?? data['id'] ?? 'unknown';
        try {
          final service = FlutterBackgroundService();
          final isSvcRunning = await service.isRunning();
          debugPrint(
              '[RINGTONE_DEBUG] Starting ringtone for order $orderId2. Service running: $isSvcRunning');

          if (isSvcRunning) {
            debugPrint(
                '🔔 [FG] Service is running. Invoking "startRingtone" event.');
            service.invoke('startRingtone', {
              'title': orderTitle,
              'body': orderBody,
              'nativeSoundPlaying': false
            });
          } else {
            // Service is not running (overlay/tracking was not enabled by the user).
            // Start it on-demand so the ringtone can play — same pattern used by the
            // FCM background handler to ensure consistent behaviour regardless of
            // whether the app was in the foreground or background.
            debugPrint(
                '🔔 [FG] Service is NOT running. Attempting to start service on-demand...');
            try {
              await service.startService();
              debugPrint(
                  '✅ [FG] service.startService() successfully called. Waiting 1500ms for isolate startup...');
              await Future.delayed(const Duration(milliseconds: 1500));
              // nativeSoundPlaying: false — service was started fresh from foreground,
              // so the service AudioPlayer must handle looping (no native channel sound was playing).
              debugPrint(
                  '🔔 [FG] Invoking "startRingtone" event post-service start (nativeSoundPlaying: false).');
              service.invoke('startRingtone', {
                'title': orderTitle,
                'body': orderBody,
                'nativeSoundPlaying': false
              });
            } catch (serviceStartError, serviceStartStack) {
              debugPrint(
                  '⚠️ [FG] Failed to start background service: $serviceStartError');
              debugPrint('⚠️ [FG] Stack: $serviceStartStack');
              debugPrint(
                  'ℹ️ [FG] Relying on native notification channel sound fallback since background service start failed.');
            }
          }
        } catch (e, stack) {
          debugPrint(
              '❌ [FG] General error invoking background service ringtone logic: $e');
          debugPrint('❌ [FG] Stack: $stack');
        }
      }

      _markNotificationShown(uniqueId);
      return;
    }

    final silentTitle = NotificationPayloadUtil.titleFrom(message, data);
    final silentBody = NotificationPayloadUtil.bodyFrom(message, data);
    // titleFrom() returns '' (not a generic 'Notification') when there is no real
    // content. Skip the notification entirely if both resolved strings are empty.
    if (silentTitle.isEmpty && silentBody.isEmpty) return;

    if (!_isInitialized) await initialize();

    // When only body is present, promote it to the title to avoid an empty title line.
    await showSimpleNotification(
      title: silentTitle.isNotEmpty ? silentTitle : silentBody,
      body: silentTitle.isNotEmpty ? silentBody : '',
      payload: jsonEncode(data),
      notificationId: uniqueId,
    );
    _markNotificationShown(uniqueId);
  }

  void _markNotificationShown(String uniqueId) {
    _shownNotificationIds.add(uniqueId);
    _notificationTimestamps[uniqueId] = DateTime.now();
  }

  void _cleanOldNotificationIds() {
    final now = DateTime.now();
    final keysToRemove = <String>[];
    _notificationTimestamps.forEach((id, timestamp) {
      if (now.difference(timestamp).inMinutes > 5) {
        keysToRemove.add(id);
      }
    });
    for (final id in keysToRemove) {
      _shownNotificationIds.remove(id);
      _notificationTimestamps.remove(id);
    }
  }

  Future<String?> getFCMToken() async {
    if (_firebaseMessaging == null) await _initializeFirebaseMessaging();
    return await _firebaseMessaging?.getToken();
  }

  Future<bool> saveFCMTokenToBackend({String? phone, String? platform}) async {
    try {
      if (PrefsUtil.getAccessToken() == null) return false;
      final token = await getFCMToken();
      if (token == null || token.isEmpty) return false;
      return await ApiService().saveFCMToken(
        token: token,
        phone: phone ?? PrefsUtil.getPhoneNumber(),
        platform: platform,
        appRole: AppConfig.appRole,
      );
    } catch (e) {
      return false;
    }
  }

  Future<void> _createNotificationChannel() async {
    try {
      const AndroidNotificationChannel standardChannel =
          AndroidNotificationChannel(
        AppConfig.notificationChannelId,
        AppConfig.notificationChannelName,
        description: AppConfig.notificationChannelDescription,
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: true,
      );

      const AndroidNotificationChannel silentChannel =
          AndroidNotificationChannel(
        AppConfig.silentChannelId,
        AppConfig.silentChannelName,
        description: AppConfig.silentChannelDescription,
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: true,
      );

      const AndroidNotificationChannel criticalChannel =
          AndroidNotificationChannel(
        AppConfig.criticalChannelId,
        AppConfig.criticalChannelName,
        description: AppConfig.criticalChannelDescription,
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('order_ringtone'),
        enableVibration: true,
        showBadge: true,
        enableLights: true,
        ledColor: Colors.red,
      );

      const AndroidNotificationChannel criticalChannelSilent =
          AndroidNotificationChannel(
        AppConfig.criticalChannelSilentId,
        AppConfig.criticalChannelSilentName,
        description: AppConfig.criticalChannelSilentDescription,
        importance: Importance.max,
        playSound: false,
        enableVibration: true,
        showBadge: true,
        enableLights: true,
        ledColor: Colors.red,
      );

      final androidImplementation =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidImplementation != null) {
        await androidImplementation
            .deleteNotificationChannel(AppConfig.notificationChannelId);
        await androidImplementation
            .deleteNotificationChannel(AppConfig.silentChannelId);
        await androidImplementation
            .deleteNotificationChannel(AppConfig.criticalChannelId);
        await androidImplementation
            .deleteNotificationChannel(AppConfig.criticalChannelSilentId);

        await androidImplementation.createNotificationChannel(standardChannel);
        await androidImplementation.createNotificationChannel(silentChannel);
        await androidImplementation.createNotificationChannel(criticalChannel);
        await androidImplementation
            .createNotificationChannel(criticalChannelSilent);
      }
    } catch (e) {
      debugPrint('❌ Error creating notification channel: $e');
    }
  }

  void _onNotificationTapped(NotificationResponse response) {
    if (response.payload != null) {
      try {
        final Map<String, dynamic> data = jsonDecode(response.payload!);
        _handleNotificationTap(data);
      } catch (e) {
        _handleNotificationTap({'payload': response.payload});
      }
    } else {
      _handleNotificationTap({});
    }
  }

  void _handleNotificationTap(Map<String, dynamic> data) {
    try {
      _platform.invokeMethod('bringToFront');
    } catch (_) {}
    _tapController.add(data);
  }

  Future<bool> requestPermission() async {
    try {
      final currentStatus = await Permission.notification.status;
      if (currentStatus.isGranted) return true;
      if (Platform.isAndroid) {
        final status = await Permission.notification.request();
        return status.isGranted;
      }
      return currentStatus.isGranted;
    } catch (e) {
      return false;
    }
  }

  Future<void> showSimpleNotification({
    required String title,
    required String body,
    String? payload,
    String? notificationId,
  }) async {
    final int localNotificationId =
        notificationId != null && notificationId.isNotEmpty
            ? notificationId.hashCode.abs() % 2147483647
            : '${title}_$body'.hashCode.abs() % 2147483647;

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      AppConfig.silentChannelId,
      AppConfig.silentChannelName,
      channelDescription: AppConfig.silentChannelDescription,
      importance: Importance.low,
      priority: Priority.low,
      playSound: false,
      enableVibration: false,
      icon: AppConfig.notificationIcon,
      showWhen: true,
      styleInformation: const BigTextStyleInformation(''),
      color: AppConfig.notificationColor,
    );

    await _notificationsPlugin.show(
      localNotificationId,
      title,
      body,
      NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(
            presentAlert: true, presentBadge: true, presentSound: false),
      ),
      payload: payload,
    );
  }

  Future<void> showOrderNotification({
    required String title,
    required String body,
    String? payload,
    String? notificationId,
    Map<String, dynamic>? orderData,
  }) async {
    final data = orderData ?? {};
    final localId = NewOrderNotificationUtil.notificationIdFor(data);

    final android = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await NewOrderNotificationUtil.ensureCriticalChannel(android);

    final service = FlutterBackgroundService();
    final bool serviceRunning = await service.isRunning();

    await _notificationsPlugin.show(
      localId,
      title,
      body,
      NewOrderNotificationUtil.buildDetails(
          playSound:
              false), // Always false so OS doesn't auto-stop sound on tap
      payload: payload,
    );
  }

  Future<void> stopOrderAlertSound({String reason = 'Unknown'}) async {
    debugPrint('[RINGTONE_DEBUG] Ringtone stopped. Reason: $reason');
    try {
      FlutterBackgroundService().invoke('stopRingtone', {'reason': reason});

      // Stop the fallback player in the FCM background isolate
      final bgPort = IsolateNameServer.lookupPortByName('bg_fcm_audio_port');
      if (bgPort != null) {
        debugPrint(
            '[RINGTONE_DEBUG] Sending stop message to bg_fcm_audio_port');
        bgPort.send('stop');
      }

      await cancelAllNotifications();

      try {
        // Initialize PrefsUtil in case we are in the background isolate where it wasn't initialized
        await PrefsUtil.init();
        if (!PrefsUtil.isOverlayEnabled()) {
          debugPrint('ℹ️ Overlay disabled. Stopping background service.');
          await Future.delayed(const Duration(milliseconds: 500));
          final service = FlutterBackgroundService();
          if (await service.isRunning()) {
            service.invoke('stopService');
          }
        }
      } catch (e) {
        debugPrint('⚠️ Error stopping service in stopOrderAlertSound: $e');
      }
    } catch (_) {}
  }

  /// Cancel all notifications posted by this app (foreground + FCM auto-shown).
  /// Used in the background isolate to remove the Android-auto-displayed notification
  /// before replacing it with the critical-channel version.
  Future<void> cancelAllNotifications() async {
    try {
      await _notificationsPlugin.cancelAll();
    } catch (e) {
      debugPrint('⚠️ cancelAllNotifications: $e');
    }
  }

  /// Handle user logout sequence.
  /// Deletes the local FCM token from Firebase SDK, stops the order ringtone,
  /// clears all active notifications, and wipes native preferences.
  Future<void> handleLogout() async {
    debugPrint(
        '🔔 NotificationService: Logging out, unregistering FCM token...');
    try {
      if (_firebaseMessaging == null) {
        _firebaseMessaging = FirebaseMessaging.instance;
      }
      await _firebaseMessaging?.deleteToken();
      debugPrint('✅ FCM token deleted from Firebase SDK successfully');
    } catch (e) {
      debugPrint('❌ Error deleting FCM token: $e');
    }

    // Stop active alarms and notifications
    await stopOrderAlertSound();
    await cancelAllNotifications();

    // Clear saved credentials
    await PrefsUtil.clearAccessToken();
    await PrefsUtil.clearPhoneNumber();
  }
}
