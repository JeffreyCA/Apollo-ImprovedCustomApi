# Standalone dylib injected into Apollo's bundled "Open in Apollo" Action
# extension (OpenInUIExtension.appex) to repair the share-sheet action on
# modern iOS. See openin-extension/ApolloOpenInFix.m and
# scripts/fix-openin-extension.sh.
#
# This is a LIBRARY, NOT a TWEAK, on purpose:
#   - a TWEAK would link CydiaSubstrate and emit a MobileSubstrate filter plist,
#     neither of which we want inside an app-extension we load via @rpath;
#   - a LIBRARY produces a plain dylib with no Substrate dependency. The swizzle
#     in ApolloOpenInFix.m is pure ObjC runtime from a constructor.
#
# It must NOT inherit the main tweak's FFmpeg/ZipArchive/FLEX. minos 14.0 is
# below the appex's MinimumOSVersion (15.0), so it loads everywhere the appex runs.
# The built dylib is consumed by scripts/fix-openin-extension.sh, which copies it
# into Apollo.app/Frameworks/ and adds an @rpath LC_LOAD_DYLIB to the appex.

TARGET = iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ApolloOpenInFix
ApolloOpenInFix_FILES = ApolloOpenInFix.m
ApolloOpenInFix_FRAMEWORKS = UIKit Foundation
ApolloOpenInFix_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new
# Loaded from the appex via @rpath/ApolloOpenInFix.dylib (the appex's existing
# @executable_path/../../Frameworks rpath resolves to the app's Frameworks/).
ApolloOpenInFix_LDFLAGS = -install_name @rpath/ApolloOpenInFix.dylib

include $(THEOS_MAKE_PATH)/library.mk
