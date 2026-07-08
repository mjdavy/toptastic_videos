#!/bin/sh

# Fail this script if any subcommand fails.
set -e

# The default execution directory of this script is the ci_scripts directory.
cd $CI_PRIMARY_REPOSITORY_PATH # change working directory to the root of your cloned repo.

# Install Flutter using git (shallow clone for speed).
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# Install Flutter artifacts for iOS (--ios), or macOS (--macos) platforms.
flutter precache --ios

# Disable Swift Package Manager so all plugins are resolved via CocoaPods.
# Flutter 3.24+ enables SPM by default; without this, plugins with Package.swift
# (e.g. shared_preferences_foundation) are skipped from pod install, causing
# "Module not found" build errors in projects not configured for SPM.
flutter config --no-enable-swift-package-manager

# Install Flutter dependencies.
flutter pub get

# Install CocoaPods via gem (more reliable in CI than Homebrew).
sudo gem install cocoapods

# Install CocoaPods dependencies.
cd ios && pod install # run `pod install` in the `ios` directory.

exit 0
