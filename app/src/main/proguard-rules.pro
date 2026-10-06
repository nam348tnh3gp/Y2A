# Giữ Chaquopy
-keep class com.chaquo.python.** { *; }
-keep class com.nam2006.y2mate.** { *; }

# Giữ Kotlin metadata
-keepattributes *Annotation*, InnerClasses, Signature, Exceptions

# Compose
-dontwarn androidx.compose.**

# JNI
-keepclasseswithmembernames class * {
    native <methods>;
}