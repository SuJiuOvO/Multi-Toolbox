# ProGuard and R8 Rules for Multi-Toolbox

# Suppress Play Store deferred components warnings when not using Play Store split APKs
-dontwarn com.google.android.play.core.**

# SharedPreferences and AndroidX DataStore
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class androidx.datastore.** { *; }
-keep class androidx.preference.** { *; }

# Flutter Engine & Plugins
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
