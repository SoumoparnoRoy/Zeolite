# ML Kit finds its components by reflection, so letting R8 rename them leaves a
# null where a registrar should be: recognition then dies with an NPE inside
# obfuscated frames, in release only. Debug builds never show it.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }

# The text-recognition plugin names every script ML Kit supports, but only the
# Latin model is on the classpath — the rest would cost ~4MB each for scripts no
# timetable here uses. R8 fails on the references rather than the absence.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
