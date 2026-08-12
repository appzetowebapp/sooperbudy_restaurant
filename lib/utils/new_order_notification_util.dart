import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:webview_master_app/config/app_config.dart';

/// Shared helpers for urgent new-order tray notifications (foreground + background).
class NewOrderNotificationUtil {
  NewOrderNotificationUtil._();

  // Note: no _channelReady flag — createNotificationChannel is idempotent
  // and static flags are NOT shared across Dart isolates (FCM background isolate).

  static int notificationIdFor(Map<String, dynamic> data) {
    final orderKey = data['orderId'] ??
        data['order_id'] ??
        data['orderMongoId'] ??
        data['id'] ??
        data['title'] ??
        DateTime.now().millisecondsSinceEpoch.toString();
    return 1000000 + (orderKey.hashCode.abs() % 899999);
  }

  static String titleFrom(RemoteMessage message, Map<String, dynamic> data) {
    return message.notification?.title ??
        data['title']?.toString() ??
        'New Order';
  }

  static String bodyFrom(RemoteMessage message, Map<String, dynamic> data) {
    final body = message.notification?.body ??
        data['body']?.toString() ??
        data['message']?.toString() ??
        '';
    if (body.isNotEmpty) return body;
    final orderId = data['orderId'] ?? data['order_id'];
    if (orderId != null) return 'Order ID: $orderId';
    return 'You have a new delivery order';
  }

  /// Ensures the critical order-alert channel exists on the device.
  /// Safe to call multiple times — Android ignores duplicate channel creation.
  /// Must be called in every isolate that shows notifications (foreground + background).
  static Future<void> ensureCriticalChannel(
    AndroidFlutterLocalNotificationsPlugin? android,
  ) async {
    if (android == null) return;
    try {
      debugPrint('ℹ️ Ensuring critical notification channels (sound: "${AppConfig.criticalChannelId}", silent: "${AppConfig.criticalChannelSilentId}")');
      
      // Sound critical channel (fallback)
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
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
        ),
      );

      // Silent critical channel (primary, sound played by service)
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          AppConfig.criticalChannelSilentId,
          AppConfig.criticalChannelSilentName,
          description: AppConfig.criticalChannelSilentDescription,
          importance: Importance.max,
          playSound: false,
          enableVibration: true,
          showBadge: true,
          enableLights: true,
          ledColor: Colors.red,
        ),
      );

      debugPrint('✅ Critical notification channels ensured');
    } catch (e, stack) {
      debugPrint('❌ Error ensuring critical notification channels: $e');
      debugPrint('$stack');
    }
  }

  static NotificationDetails buildDetails({required bool playSound}) {
    debugPrint('ℹ️ Building NotificationDetails (playSound: $playSound) for critical channel (sound: "${AppConfig.criticalChannelId}", silent: "${AppConfig.criticalChannelSilentId}")');
    return NotificationDetails(
      android: AndroidNotificationDetails(
        playSound ? AppConfig.criticalChannelId : AppConfig.criticalChannelSilentId,
        playSound ? AppConfig.criticalChannelName : AppConfig.criticalChannelSilentName,
        channelDescription: playSound ? AppConfig.criticalChannelDescription : AppConfig.criticalChannelSilentDescription,
        importance: Importance.max,
        priority: Priority.max,
        playSound: playSound,
        sound: playSound ? const RawResourceAndroidNotificationSound('order_ringtone') : null,
        enableVibration: true,
        icon: AppConfig.notificationIcon,
        visibility: NotificationVisibility.public,
        styleInformation: const BigTextStyleInformation(''),
        colorized: true,
        color: Colors.red,
        showWhen: true,
        autoCancel: true,
        ongoing: false,
        channelShowBadge: true,
        ticker: 'New order received',
        additionalFlags: playSound ? Int32List.fromList(<int>[4]) : null, // FLAG_INSISTENT (loops sound until dismissed/clicked)
        audioAttributesUsage: AudioAttributesUsage.alarm, // Directs OS to treat this as alarm (respects user alarms, bypasses standard muting)
        category: AndroidNotificationCategory.alarm, // Higher visibility/DND bypass capability
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: '${AppConfig.notificationSoundName}.mp3',
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }

  /// Posts the tray notification. [fromBackgroundIsolate] skips permission_handler
  /// (it often returns false in the FCM background isolate even when allowed).
  static Future<bool> show(
    FlutterLocalNotificationsPlugin plugin, {
    required RemoteMessage message,
    bool fromBackgroundIsolate = false,
  }) async {
    final data = Map<String, dynamic>.from(message.data);
    final title = titleFrom(message, data);
    final body = bodyFrom(message, data);
    final id = notificationIdFor(data);
    final payload = jsonEncode(data);

    if (!fromBackgroundIsolate) {
      try {
        if (!await Permission.notification.isGranted) {
          debugPrint(
              '❌ POST_NOTIFICATIONS not granted — cannot show tray notification');
          return false;
        }
      } catch (e) {
        debugPrint('⚠️ Permission check failed, attempting show anyway: $e');
      }
    }

    try {
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await ensureCriticalChannel(android);

      final service = FlutterBackgroundService();
      final bool serviceRunning = await service.isRunning();

      await plugin.show(
        id,
        title,
        body,
        buildDetails(playSound: !serviceRunning),
        payload: payload,
      );
      debugPrint('✅ Tray notification posted (id=$id, playSound=${!serviceRunning}): $title | $body');
      return true;
    } catch (e, stack) {
      debugPrint('❌ Failed to post tray notification: $e');
      debugPrint('$stack');
      return false;
    }
  }
}
