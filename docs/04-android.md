# Android build on this host (aarch64)

Google publishes Linux SDK tools for x86_64 only, and this box is aarch64. The build works by
running the few native SDK binaries (aapt2, adb) through qemu's binfmt handler; Gradle, the Kotlin
compiler and `d8/r8` are JVM programs and run natively.

## One-time setup

```bash
sudo apt-get install -y qemu-user-static binfmt-support   # qemu-x86_64 must be registered
# JDK 21 is required by AGP 9; the default java is 25.
```

Official command-line tools (x86_64, but only the launcher shell is native — sdkmanager is Java):

```bash
mkdir -p ~/android-sdk/cmdline-tools && cd /tmp
curl -O https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip -q commandlinetools-linux-11076708_latest.zip -d /tmp/cmd
mv /tmp/cmd/cmdline-tools ~/android-sdk/cmdline-tools/latest

export ANDROID_HOME=~/android-sdk JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64
yes | ~/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME --licenses
~/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0"
```

Verify the emulation path: `~/android-sdk/build-tools/36.0.0/aapt2 version` must print a version.

## Flutter specifics

The nix Flutter package patches `gradle.dart` to require `NIX_AAPT2_BINARY_PATH`; without it, Flutter
passes `-Pandroid.aapt2FromMavenOverride=null` and AGP fails with
`Custom AAPT2 location does not point to an AAPT2 executable: null`. Point it at the SDK's aapt2.

`android/local.properties`:

```
sdk.dir=/home/ubuntu/android-sdk
flutter.sdk=/nix/store/<flutter-wrapped>-sdk-links
```

`pubspec.yaml` needs both platform libraries: `media_kit_libs_linux` and
`media_kit_libs_android_video` (without the Android one the APK has no `libmpv.so` and playback
fails at runtime while the build still succeeds — check with `unzip -l ... | grep mpv`).

## Build

```bash
nix shell nixpkgs#flutter -c bash -c '
  export ANDROID_HOME=/home/ubuntu/android-sdk ANDROID_SDK_ROOT=$ANDROID_HOME
  export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64
  export NIX_AAPT2_BINARY_PATH=$ANDROID_HOME/build-tools/36.0.0/aapt2
  export PATH=$JAVA_HOME/bin:$PATH
  cd app && flutter build apk --release
'
```

Output: `app/build/app/outputs/flutter-apk/app-release.apk`. Release uses the debug signing config
from the Flutter template, so it installs but is not Play-Store signed.

## Release builds do not work with the nix SDK on aarch64

`flutter build apk --release` fails in `compileFlutterBuildRelease`:

```
Failed to find ".../bin/cache/artifacts/engine/android-arm64-release/linux-arm64/gen_snapshot"
```

The nix Flutter package ships the JIT engine but not the Android AOT `gen_snapshot` binaries for
`linux-arm64`, and the store is read-only so `flutter precache` cannot fetch them. Debug builds are
unaffected. For a release APK, build on an x86_64 host with the official SDK, or use a Flutter SDK
unpacked into a writable directory and run `flutter precache --android`.

What ships from this host is a debug build split per ABI:

```bash
nix shell nixpkgs#flutter -c bash -c '
  export ANDROID_HOME=/home/ubuntu/android-sdk ANDROID_SDK_ROOT=$ANDROID_HOME
  export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64
  export NIX_AAPT2_BINARY_PATH=$ANDROID_HOME/build-tools/36.0.0/aapt2
  export PATH=$JAVA_HOME/bin:$PATH
  cd app && flutter build apk --debug --split-per-abi
'
```

`app-arm64-v8a-debug.apk` is the phone build.


## Known limits

- qemu makes aapt2 slow; expect the first build to take several minutes.
- No emulator on aarch64 Linux, so runtime testing needs a real device over `adb` (platform-tools
  present, `adb devices`).
- The APK is large in debug (153 MB, three ABIs). Release with `--split-per-abi` is the sane
  distribution shape.
