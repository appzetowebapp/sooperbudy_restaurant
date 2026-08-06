package com.buddyserviceappzeto.restaurant

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.media.AudioManager
import android.util.Log
import androidx.core.app.NotificationManagerCompat

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.buddyserviceappzeto.restaurant/geolocation"
    private val LOCATION_PERMISSION_REQUEST_CODE = 1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Geolocation channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkLocationPermission" -> {
                    val hasPermission = checkLocationPermission()
                    result.success(hasPermission)
                }
                "requestLocationPermission" -> {
                    requestLocationPermission()
                    result.success(true)
                }
                "bringToFront" -> {
                    val intent = packageManager.getLaunchIntentForPackage(packageName)
                    if (intent != null) {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        startActivity(intent)
                        result.success(true)
                    } else {
                        // Fallback to existing activity if launch intent is null
                        val fallbackIntent = Intent(this, MainActivity::class.java)
                        fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        startActivity(fallbackIntent)
                        result.success(true)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun checkLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestLocationPermission() {
        if (!checkLocationPermission()) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ),
                LOCATION_PERMISSION_REQUEST_CODE
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!checkLocationPermission()) {
            requestLocationPermission()
        }
    }

    /**
     * Called when the Activity is being destroyed — including when the user
     * swipes the app away from the Recent Apps list on most Android devices.
     * We stop the background service (which owns the AudioPlayer ringtone) and
     * cancel all active notifications to ensure the ringtone stops immediately.
     *
     * Note: The Flutter AppLifecycleState.detached handler in main.dart also
     * sends stopRingtone via the service invoke API. This native-level cleanup
     * acts as a safety net in case the Dart isolate is torn down first.
     */
    override fun onDestroy() {
        Log.d("MainActivity", "onDestroy: Activity destroyed. Stopping ringtone and services.")

        // 1. Stop the FlutterBackgroundService by sending a stop intent
        try {
            val stopIntent = Intent(this, Class.forName("id.flutter.flutter_background_service.BackgroundService"))
            stopService(stopIntent)
            Log.d("MainActivity", "onDestroy: Background service stop requested.")
        } catch (e: Exception) {
            Log.e("MainActivity", "onDestroy: Error stopping background service: ${e.message}")
        }

        // 2. Cancel all notifications
        try {
            NotificationManagerCompat.from(this).cancelAll()
            Log.d("MainActivity", "onDestroy: All notifications cancelled.")
        } catch (e: Exception) {
            Log.e("MainActivity", "onDestroy: Error cancelling notifications: ${e.message}")
        }

        // 3. Abandon audio focus to silence any lingering audio
        try {
            val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
            audioManager.abandonAudioFocus(null)
            Log.d("MainActivity", "onDestroy: Audio focus abandoned.")
        } catch (e: Exception) {
            Log.e("MainActivity", "onDestroy: Error abandoning audio focus: ${e.message}")
        }

        super.onDestroy()
    }
}
