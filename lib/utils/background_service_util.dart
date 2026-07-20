import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:webview_master_app/config/app_config.dart';

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

// ---------------------------------------------------------------------------
// Top-level state — these values persist as long as the Dart isolate is alive.
// flutter_background_service reuses the same Dart isolate across startService()
// calls on some Android versions/OEMs, so we MUST cancel and re-register
// subscriptions on every onStart() invocation instead of guarding with a flag.
// ---------------------------------------------------------------------------
AudioPlayer? _audioPlayer;
bool _isRinging = false;
Timer? _locationTimer;

// Tracked subscriptions so we can cancel them before re-registering on restart.
StreamSubscription<Map<String, dynamic>?>? _subSetFg;
StreamSubscription<Map<String, dynamic>?>? _subSetBg;
StreamSubscription<Map<String, dynamic>?>? _subStartRingtone;
StreamSubscription<Map<String, dynamic>?>? _subStopRingtone;
StreamSubscription<Map<String, dynamic>?>? _subStopService;

@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  debugPrint('[RINGTONE_DEBUG] background_service_util onStart() triggered.');

  // Create a single, persistent AudioPlayer for the lifetime of this service isolate
  if (_audioPlayer == null) {
    _audioPlayer = AudioPlayer();
    try {
      await _audioPlayer!.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.alarm,
            contentType: AndroidContentType.sonification,
            audioFocus: AndroidAudioFocus.gain,
          ),
        ),
      );
      await _audioPlayer!.setReleaseMode(ReleaseMode.loop);
    } catch (e) {
      debugPrint(
        '[RINGTONE_DEBUG] Error configuring persistent AudioPlayer: $e',
      );
    }
  }

  // -------------------------------------------------------------------------
  // STEP 1: Reset ringtone state and clean up any stale player on every start.
  // -------------------------------------------------------------------------
  debugPrint(
    '[RINGTONE_DEBUG] Previous _isRinging=$_isRinging, stale player=${_audioPlayer != null}',
  );

  _isRinging = false;
  debugPrint(
    '[RINGTONE_DEBUG] State after reset: _isRinging=$_isRinging, player=${_audioPlayer != null}',
  );

  // -------------------------------------------------------------------------
  // STEP 2: Cancel ALL existing subscriptions before re-registering.
  // This is the core fix: prevents a) duplicate listeners on isolate reuse,
  // and b) the "skipped second order" bug caused by the old _initialized guard
  // that prevented listener re-registration after a stop/restart cycle.
  // -------------------------------------------------------------------------
  debugPrint(
    '[RINGTONE_DEBUG] Cancelling existing event subscriptions before re-registering...',
  );
  await _subSetFg?.cancel();
  _subSetFg = null;
  await _subSetBg?.cancel();
  _subSetBg = null;
  await _subStartRingtone?.cancel();
  _subStartRingtone = null;
  await _subStopRingtone?.cancel();
  _subStopRingtone = null;
  await _subStopService?.cancel();
  _subStopService = null;
  _locationTimer?.cancel();
  _locationTimer = null;
  debugPrint(
    '[RINGTONE_DEBUG] All previous subscriptions cancelled. Registering fresh listeners...',
  );

  // -------------------------------------------------------------------------
  // STEP 3: Register foreground-service control listeners (Android only).
  // -------------------------------------------------------------------------
  if (service is AndroidServiceInstance) {
    _subSetFg = service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });

    _subSetBg = service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });

    service.setForegroundNotificationInfo(
      title: 'Sooperbuddy Reastaurant Service Active',
      content: 'Waiting for new orders...',
    );
  }

  // -------------------------------------------------------------------------
  // STEP 4: Register startRingtone listener (Android only).
  // -------------------------------------------------------------------------
  if (service is AndroidServiceInstance) {
    _subStartRingtone = service.on('startRingtone').listen((event) async {
      final orderId =
          event?['data']?['orderId'] ??
          event?['data']?['order_id'] ??
          'unknown';
      debugPrint('[RINGTONE_DEBUG] ── startRingtone received ──');
      debugPrint('[RINGTONE_DEBUG] Order ID: $orderId');

      if (_isRinging) {
        debugPrint(
          '[RINGTONE_DEBUG] Ringtone start skipped reason: already playing',
        );
        return;
      }

      // Start fresh playback
      _isRinging = true;
      debugPrint(
        '[RINGTONE_DEBUG] Playing persistent AudioPlayer for order $orderId...',
      );
      try {
        // Always create a fresh player if the previous one was disposed
        if (_audioPlayer == null) {
          _audioPlayer = AudioPlayer();
          try {
            await _audioPlayer!.setAudioContext(
              AudioContext(
                android: const AudioContextAndroid(
                  usageType: AndroidUsageType.alarm,
                  contentType: AndroidContentType.sonification,
                  audioFocus: AndroidAudioFocus.gain,
                ),
              ),
            );
          } catch (_) {}
          await _audioPlayer!.setReleaseMode(ReleaseMode.loop);
        }
        await _audioPlayer!.play(AssetSource('audio/order_ringtone.mp3'));
        debugPrint(
          '[RINGTONE_DEBUG] Ringtone started successfully. _isRinging=$_isRinging',
        );
      } catch (e, stack) {
        debugPrint('[RINGTONE_DEBUG] Error starting ringtone: $e');
        debugPrint('[RINGTONE_DEBUG] Stack: $stack');
        // Player may be in a bad state — dispose and null so next attempt recreates it
        try {
          await _audioPlayer?.dispose();
        } catch (_) {}
        _audioPlayer = null;
        _isRinging = false;
      }
    });
    debugPrint('[RINGTONE_DEBUG] startRingtone listener registered ✓');
  }

  // -------------------------------------------------------------------------
  // STEP 5: Register stopRingtone listener (Android only).
  // -------------------------------------------------------------------------
  if (service is AndroidServiceInstance) {
    _subStopRingtone = service.on('stopRingtone').listen((event) async {
      final String reason = event?['reason']?.toString() ?? 'Unknown';
      debugPrint('[RINGTONE_DEBUG] ── stopRingtone received ──');
      debugPrint('[RINGTONE_DEBUG] Reason: $reason');

      _isRinging = false;

      // Dispose the player fully so native MediaPlayer resources are released.
      // A fresh player will be created on the next startRingtone event.
      final player = _audioPlayer;
      _audioPlayer = null;
      if (player != null) {
        try {
          await player.stop();
        } catch (_) {}
        try {
          await player.dispose();
        } catch (_) {}
      }

      debugPrint(
        '[RINGTONE_DEBUG] Ringtone stopped and player disposed. State after stop: _isRinging=$_isRinging',
      );

      try {
        service.setForegroundNotificationInfo(
          title: 'Sooperbuddy Reastaurant Service Active',
          content: 'Waiting for new orders...',
        );
      } catch (_) {}
    });
    debugPrint('[RINGTONE_DEBUG] stopRingtone listener registered ✓');
  }

  // -------------------------------------------------------------------------
  // STEP 6: Register stopService listener (all platforms).
  // -------------------------------------------------------------------------
  _subStopService = service.on('stopService').listen((event) async {
    debugPrint('[RINGTONE_DEBUG] ── stopService received ──');
    _locationTimer?.cancel();
    _locationTimer = null;
    _isRinging = false;

    try {
      if (_audioPlayer != null) {
        await _audioPlayer!.stop();
        await _audioPlayer!.dispose(); // Dispose only on full service stop
        _audioPlayer = null;
      }
    } catch (_) {}

    // Cancel all subscriptions cleanly before stopping
    await _subSetFg?.cancel();
    _subSetFg = null;
    await _subSetBg?.cancel();
    _subSetBg = null;
    await _subStartRingtone?.cancel();
    _subStartRingtone = null;
    await _subStopRingtone?.cancel();
    _subStopRingtone = null;
    // Note: _subStopService cancels itself by stopping the service below

    debugPrint(
      '[RINGTONE_DEBUG] Service stopped cleanly. _isRinging=$_isRinging, player=${_audioPlayer != null}',
    );
    service.stopSelf();
  });
  debugPrint('[RINGTONE_DEBUG] stopService listener registered ✓');

  // -------------------------------------------------------------------------
  // STEP 7: Location tracking timer (reset and restart every onStart call).
  // -------------------------------------------------------------------------
  _locationTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
    if (service is AndroidServiceInstance) {
      if (!(await service.isForegroundService())) return;

      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );

        debugPrint(
          '📍 Background Location: ${position.latitude}, ${position.longitude}',
        );

        service.invoke('update', {
          'latitude': position.latitude,
          'longitude': position.longitude,
        });
      } catch (e) {
        debugPrint('❌ Background Location Error: $e');
      }
    }
  });

  debugPrint(
    '[RINGTONE_DEBUG] onStart() complete. All listeners registered and location timer started.',
  );
}

@pragma('vm:entry-point')
class BackgroundServiceUtil {
  static const int notificationId = 888;

  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: AppConfig.silentChannelId,
        initialNotificationTitle: 'Restaurant service active',
        initialNotificationContent: 'Waiting for new orders...',
        foregroundServiceNotificationId: notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  static Future<void> start() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (isRunning) {
      service.invoke('stopService');
    }
  }

  static Future<bool> isRunning() async {
    final service = FlutterBackgroundService();
    return await service.isRunning();
  }
}
