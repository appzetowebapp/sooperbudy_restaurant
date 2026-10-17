import 'dart:ui';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'package:audioplayers/audioplayers.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:webview_master_app/utils/new_order_notification_util.dart';
import 'package:webview_master_app/utils/notification_service.dart';
import 'package:webview_master_app/utils/notification_payload_util.dart';
import 'package:webview_master_app/utils/prefs_util.dart';

AudioPlayer? _bgAudioPlayer;
ReceivePort? _bgReceivePort;

/// Background message handler for Firebase Cloud Messaging.
/// Must be a top-level function — runs when app is backgrounded or terminated.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  // Setup inter-isolate communication port to receive stop signals from main isolate
  if (_bgReceivePort == null) {
    if (IsolateNameServer.lookupPortByName('bg_fcm_audio_port') != null) {
      IsolateNameServer.removePortNameMapping('bg_fcm_audio_port');
    }
    _bgReceivePort = ReceivePort();
    IsolateNameServer.registerPortWithName(_bgReceivePort!.sendPort, 'bg_fcm_audio_port');
    _bgReceivePort!.listen((msg) async {
      debugPrint('[RINGTONE_DEBUG] Fallback BG Port received message: $msg');
      if (msg == 'stop') {
        final player = _bgAudioPlayer;
        _bgAudioPlayer = null;
        if (player != null) {
          try {
            debugPrint('[RINGTONE_DEBUG] Ringtone stop requested. Reason: Inter-isolate port stop command');
            await player.stop();
          } catch (_) {}
          try {
            await player.dispose();
          } catch (_) {}
        }
      }
    });
  }

  try {
    await Firebase.initializeApp();
  } catch (_) {}

  try {
    await PrefsUtil.init();
  } catch (_) {}

  if (PrefsUtil.getAccessToken() == null) {
    debugPrint('📨 [BG] Background message received but user is logged out. Ignoring.');
    return;
  }

  try {
    debugPrint('📨 [BG] Background message received');
    debugPrint('🔍 [BG] RAW FCM PAYLOAD MAP: ${message.toMap()}');
    
    Map<String, dynamic> data = Map<String, dynamic>.from(message.data);
    RemoteNotification? notification = message.notification;

    if (notification != null) {
      if (!data.containsKey('title') || data['title'] == null) {
        data['title'] = notification.title;
      }
      if (!data.containsKey('body') || data['body'] == null) {
        data['body'] = notification.body;
      }
    }

    final type = (data['type'] ?? data['notification_type'] ?? data['click_action'] ?? data['event'] ?? '')
        .toString()
        .toLowerCase()
        .trim();

    debugPrint('Notification Type = $type');

    if (type == 'new_order') {
      debugPrint('=> Start ringtone');
    } else if (type == 'order_status_update') {
      debugPrint('=> Stop ringtone');
      final serviceInstance = NotificationService();
      await serviceInstance.initialize(isBackground: true);
      await serviceInstance.stopOrderAlertSound(reason: 'Order status update FCM (Background)');
      
      // Stop the local player too
      final player = _bgAudioPlayer;
      _bgAudioPlayer = null;
      if (player != null) {
        debugPrint('[RINGTONE_DEBUG] Ringtone stop requested. Reason: Order status update FCM (Background)');
        try { await player.stop(); } catch (_) {}
        try { await player.dispose(); } catch (_) {}
      }
    } else if (NotificationService.isCancelOrExpireNotification(data) ||
               type == 'order_accepted' ||
               type == 'order_rejected' ||
               type == 'order_cancelled' ||
               type == 'order_expired') {
      debugPrint('=> Stop ringtone');
      final serviceInstance = NotificationService();
      await serviceInstance.initialize(isBackground: true);
      await serviceInstance.stopOrderAlertSound(reason: 'Order accepted/rejected/cancelled/expired FCM ($type) (Background)');
      
      // Stop the local player too
      final player2 = _bgAudioPlayer;
      _bgAudioPlayer = null;
      if (player2 != null) {
        debugPrint('[RINGTONE_DEBUG] Ringtone stop requested. Reason: Order accepted/rejected/cancelled/expired FCM ($type) (Background)');
        try { await player2.stop(); } catch (_) {}
        try { await player2.dispose(); } catch (_) {}
      }
    }

    final isNewOrder = NotificationService.isNewOrderNotification(data);
    final title = NewOrderNotificationUtil.titleFrom(message, data);
    final body = NewOrderNotificationUtil.bodyFrom(message, data);

    if (isNewOrder) {
      debugPrint('🔔 [BG] New order confirmed — showing system tray notification and sounding alarm.');

      final serviceInstance = NotificationService();
      await serviceInstance.initialize(isBackground: true);

      // When the FCM payload includes a `notification` object, the Android OS
      // auto-displays it on the default (silent) channel BEFORE this handler runs.
      // Cancel that auto-notification so only the critical-channel version appears.
      if (message.notification != null) {
        debugPrint('ℹ️ [BG] FCM notification payload present — cancelling auto-shown notification before showing critical alert.');
        // Wait a short delay to ensure the Android OS has fully rendered the auto-displayed notification before we cancel it
        await Future.delayed(const Duration(milliseconds: 600));
        await serviceInstance.cancelAllNotifications();
      }

      String notificationId = message.messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

      await serviceInstance.showOrderNotification(
        title: title.isNotEmpty ? title : 'New Order',
        body: body.isNotEmpty ? body : 'You have a new delivery order',
        notificationId: notificationId,
        orderData: data,
      );

      if (type == 'new_order') {
        try {
          final service = FlutterBackgroundService();
          final orderPayload = {
            'title': title,
            'body': body,
            'data': data,
            'nativeSoundPlaying': false,
          };
          
          final isSvcRunning = await service.isRunning();
          debugPrint('ℹ️ [BG] FlutterBackgroundService.isRunning() = $isSvcRunning. Android SDK version: ${Platform.isAndroid ? 'Android' : 'Other'}');
          
          if (isSvcRunning) {
            debugPrint('🔔 [BG] Service is already running. Invoking "startRingtone" event (nativeSoundPlaying: false).');
            service.invoke('startRingtone', orderPayload);
          } else {
            debugPrint('🔔 [BG] Service is NOT running. Attempting to start service from background state...');
            final fallbackPayload = Map<String, dynamic>.from(orderPayload);
            fallbackPayload['nativeSoundPlaying'] = false; // Always false, AudioPlayer must handle it
            try {
              await service.startService();
              debugPrint('✅ [BG] service.startService() successfully called. Waiting 1500ms for isolate startup...');
              await Future.delayed(const Duration(milliseconds: 1500));
              debugPrint('🔔 [BG] Invoking "startRingtone" event post-service start (nativeSoundPlaying: false).');
              service.invoke('startRingtone', fallbackPayload);
            } catch (serviceStartError, serviceStartStack) {
              debugPrint('⚠️ [BG] Failed to start background service (this is expected on Android 12+ background starts due to OS/OEM restrictions): $serviceStartError');
              debugPrint('⚠️ [BG] Stack: $serviceStartStack');
              debugPrint('ℹ️ [BG] Relying on fallback local AudioPlayer since background service start was restricted.');
              
              // Start local fallback player since background service failed to start
              try {
                if (_bgAudioPlayer != null) {
                  debugPrint('[RINGTONE_DEBUG] Stale fallback player detected. Stopping before new start.');
                  try {
                    await _bgAudioPlayer!.stop();
                  } catch (_) {}
                } else {
                  _bgAudioPlayer = AudioPlayer();
                  await _bgAudioPlayer!.setAudioContext(
                     AudioContext(
                      android: AudioContextAndroid(
                        usageType: AndroidUsageType.alarm,
                        contentType: AndroidContentType.sonification,
                        audioFocus: AndroidAudioFocus.gain,
                      ),
                    ),
                  );
                  await _bgAudioPlayer!.setReleaseMode(ReleaseMode.loop);
                }
                
                debugPrint('[RINGTONE_DEBUG] Ringtone start requested. Isolate: BG Fallback Isolate, Path: assets/audio/order_ringtone.mp3');
                await _bgAudioPlayer!.play(AssetSource('audio/order_ringtone.mp3'));
                debugPrint('[RINGTONE_DEBUG] Ringtone loop status: Loop enabled (ReleaseMode.loop). Current state: Playing');
              } catch (playerErr) {
                debugPrint('[RINGTONE_DEBUG] Playback error: $playerErr');
              }
            }
          }
        } catch (e, stack) {
          debugPrint('❌ [BG] General error invoking background service ringtone logic: $e');
          debugPrint('❌ [BG] Stack: $stack');
        }
      }
      return;
    }

    debugPrint('🔕 [BG] Status/other notification captured — forcing silent tray insertion.');
    
    // FCM automatically displays background notifications if the payload contains a "notification" object.
    if (message.notification != null) {
      final autoTitle = (message.notification!.title ?? '').trim();
      final autoBody  = (message.notification!.body  ?? '').trim();

      if (autoTitle.isEmpty && autoBody.isEmpty) {
        // The FCM payload carried an empty notification object. Android OS
        // auto-showed a blank notification before this handler ran. Cancel it.
        final svc = NotificationService();
        await svc.initialize(isBackground: true);
        // Wait a short delay to ensure the Android OS has fully rendered the auto-displayed notification before we cancel it
        await Future.delayed(const Duration(milliseconds: 600));
        await svc.cancelAllNotifications();
        debugPrint('ℹ️ [BG] Cancelled blank auto-FCM notification (empty title+body).');
      } else {
        debugPrint('ℹ️ [BG] Non-blank FCM notification payload — Android OS already displayed it silently. Skipping duplicate manual show.');
      }
      return;
    }

    final silentTitle = NotificationPayloadUtil.titleFrom(message, data);
    final silentBody = NotificationPayloadUtil.bodyFrom(message, data);
    
    // Skip truly empty payloads. titleFrom() now returns '' (not 'Notification')
    // when there is no real content, so this guard now works correctly.
    if (silentTitle.isEmpty && silentBody.isEmpty) {
      debugPrint('ℹ️ [BG] Empty non-order payload, skipping system notification stack.');
      return;
    }

    final serviceInstance = NotificationService();
    await serviceInstance.initialize(isBackground: true);

    String notificationId = message.messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

    await serviceInstance.showSimpleNotification(
      title: silentTitle.isNotEmpty ? silentTitle : silentBody,
      body: silentTitle.isNotEmpty ? silentBody : '',
      notificationId: notificationId,
    );

  } catch (e, stack) {
    debugPrint('❌ [BG] FATAL ERROR: $e');
    debugPrint('❌ [BG] STACK: $stack');
  }
}