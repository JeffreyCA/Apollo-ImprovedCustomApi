export ARCHS = arm64
export libFLEX_ARCHS = arm64

TARGET := iphone:clang:26.0:14.0
INSTALL_TARGET_PROCESSES = Apollo
THEOS_LEAN_AND_MEAN = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ApolloReborn

SRC_DIR := src
MODULES_DIR := modules
SSZIPARCHIVE_DIR := $(MODULES_DIR)/ZipArchive/SSZipArchive
FFMPEG_KIT_DIR := $(MODULES_DIR)/ffmpeg-kit
FLEXING_DIR := $(MODULES_DIR)/FLEXing

SSZIPARCHIVE_FILES = $(wildcard $(SSZIPARCHIVE_DIR)/*.m) \
    $(wildcard $(SSZIPARCHIVE_DIR)/minizip/*.c) \
    $(wildcard $(SSZIPARCHIVE_DIR)/minizip/compat/*.c)

ApolloReborn_FILES = \
    $(SRC_DIR)/Tweak.xm \
    $(SRC_DIR)/ApolloCommon.m \
    $(SRC_DIR)/ApolloSettingsTableViewController.m \
    $(SRC_DIR)/ApolloRedditMediaUpload.m \
    $(SRC_DIR)/ApolloNotificationBackend.m \
    $(SRC_DIR)/ApolloPushNotifications.m \
    $(SRC_DIR)/ApolloUserProfileCache.m \
    $(SRC_DIR)/ApolloSubredditInfoCache.m \
    $(SRC_DIR)/ApolloSubredditCustomBannerCache.m \
    $(SRC_DIR)/ApolloSubredditCustomIconCache.m \
    $(SRC_DIR)/ApolloSubredditDefaultAssets.c \
    $(SRC_DIR)/ApolloUserAvatars.xm \
    $(SRC_DIR)/ApolloProfileSocialLinks.m \
    $(SRC_DIR)/ApolloModeratorAvatars.xm \
    $(SRC_DIR)/ApolloSubredditHeaders.xm \
    $(SRC_DIR)/ApolloSubredditHighlights.xm \
    $(SRC_DIR)/ApolloBannedProfile.xm \
    $(SRC_DIR)/ApolloImageUploadHost.xm \
    $(SRC_DIR)/ApolloPhotoPostComposerScrollFix.xm \
    $(SRC_DIR)/ApolloMarkdownToolbarGif.xm \
    $(SRC_DIR)/ApolloMarkdownBodyCleanup.xm \
    $(SRC_DIR)/ApolloGiphyClient.m \
    $(SRC_DIR)/GiphyPickerViewController.m \
    $(SRC_DIR)/ApolloCreatedAtAlert.xm \
    $(SRC_DIR)/ApolloDeletedCommentsData.m \
    $(SRC_DIR)/ApolloDeletedCommentsUI.xm \
    $(SRC_DIR)/ApolloState.m \
    $(SRC_DIR)/ApolloShareLinks.xm \
    $(SRC_DIR)/ApolloMedia.xm \
    $(SRC_DIR)/ApolloMediaMetadata.m \
    $(SRC_DIR)/ApolloMediaAutoplay.m \
    $(SRC_DIR)/ApolloCommentsCollapse.xm \
    $(SRC_DIR)/ApolloInboxCommentScroll.xm \
    $(SRC_DIR)/ApolloLiquidGlass.xm \
    $(SRC_DIR)/ApolloLiquidGlassIconPicker.xm \
    $(SRC_DIR)/ApolloAutoHideTabBar.xm \
    $(SRC_DIR)/ApolloSettings.xm \
    $(SRC_DIR)/ApolloRecentlyRead.xm \
    $(SRC_DIR)/ApolloSavedCategories.xm \
    $(SRC_DIR)/ApolloUserFlair.xm \
    $(SRC_DIR)/ApolloFlairColors.xm \
    $(SRC_DIR)/ApolloNativeActionMenus.xm \
    $(SRC_DIR)/ApolloShareAsImageGallery.xm \
    $(SRC_DIR)/ApolloShareAsImageLink.xm \
    $(SRC_DIR)/ApolloShareAsVideo.xm \
    $(SRC_DIR)/ApolloShareAsImagePreviewFix.xm \
    $(SRC_DIR)/ApolloTranslation.xm \
    $(SRC_DIR)/ApolloAppleTranslation.swift \
    $(SRC_DIR)/ApolloVideoUnmute.xm \
    $(SRC_DIR)/ApolloVideoSwipeFix.xm \
    $(SRC_DIR)/ApolloVideoPlaybackSpeed.xm \
    $(SRC_DIR)/ApolloVideoHoldSpeed.xm \
    $(SRC_DIR)/ApolloPictureInPicture.xm \
    $(SRC_DIR)/ApolloMediaPreviewErrorFix.xm \
    $(SRC_DIR)/ApolloSubredditIndexPolish.xm \
    $(SRC_DIR)/ApolloQuickActions.xm \
    $(SRC_DIR)/ApolloHideModSubreddits.xm \
    $(SRC_DIR)/ApolloSubredditSidebar.xm \
    $(SRC_DIR)/ApolloTagFilters.xm \
    $(SRC_DIR)/ApolloThemeBuilder.xm \
    $(SRC_DIR)/ApolloThemeBuilderViewController.m \
    $(SRC_DIR)/ApolloSearchInPlace.xm \
    $(SRC_DIR)/ApolloSearchHeaderOverlapFix.xm \
    $(SRC_DIR)/ApolloImageChestResolver.m \
    $(SRC_DIR)/ApolloImgChestUpload.m \
    $(SRC_DIR)/ApolloLinkPreviewModel.m \
    $(SRC_DIR)/ApolloLinkPreviewCache.m \
    $(SRC_DIR)/ApolloLinkPreviewFetcher.m \
    $(SRC_DIR)/ApolloInlineImages.xm \
    $(SRC_DIR)/ApolloInlineLinkPreviews.xm \
    $(SRC_DIR)/ApolloFeedTextPostThumbnails.xm \
    $(SRC_DIR)/ApolloTweetBuddy.xm \
	$(SRC_DIR)/ApolloVisionOSFix.xm \
    $(SRC_DIR)/ApolloWebAuthViewController.m \
    $(SRC_DIR)/ApolloWebJSON.m \
    $(SRC_DIR)/ApolloWebJSONIdentity.xm \
    $(SRC_DIR)/ApolloWebSessionLoginViewController.m \
    $(SRC_DIR)/ApolloWebSessionStore.m \
    $(SRC_DIR)/ApolloManualSignInViewController.m \
    $(SRC_DIR)/ApolloAccountCredentials.m \
    $(SRC_DIR)/ApolloAccountSwitcherViewController.xm \
    $(SRC_DIR)/ApolloSignInSplash.xm \
    $(SRC_DIR)/CustomAPIViewController.m \
    $(SRC_DIR)/ApolloLinkPreviewSettingsViewController.m \
    $(SRC_DIR)/TranslationSettingsViewController.m \
    $(SRC_DIR)/SavedCategoriesViewController.m \
    $(SRC_DIR)/TagFiltersViewController.m \
    $(SRC_DIR)/PictureInPictureViewController.m \
    $(SRC_DIR)/Defaults.m \
    $(SRC_DIR)/UIWindow+Apollo.m \
    $(SRC_DIR)/fishhook.c \
    $(SSZIPARCHIVE_FILES)
ApolloReborn_FRAMEWORKS = UIKit Security AVFoundation AVKit OSLog NaturalLanguage ImageIO StoreKit Photos PhotosUI SafariServices SystemConfiguration WebKit AuthenticationServices CoreImage SwiftUI UniformTypeIdentifiers
ApolloReborn_LIBRARIES = z iconv
# Apple's Translation framework (used by the on-device "apple" translation provider in
# ApolloAppleTranslation.swift) only exists on iOS 18.0+. Weak-link it so the tweak still
# loads on older iOS, where the Apple provider is gated off at runtime.
ApolloReborn_LDFLAGS += -weak_framework Translation
ApolloReborn_CFLAGS = -fobjc-arc -Wno-error=unguarded-availability-new -Wno-error=deprecated-declarations -Wno-module-import-in-extern-c -I$(THEOS_PROJECT_DIR)/$(SRC_DIR) -I$(THEOS_PROJECT_DIR)/liquid-glass/generated -I$(THEOS_PROJECT_DIR)/$(MODULES_DIR) -I$(THEOS_PROJECT_DIR)/$(SSZIPARCHIVE_DIR) -I$(THEOS_PROJECT_DIR)/$(SSZIPARCHIVE_DIR)/minizip -DHAVE_ARC4RANDOM_BUF -DHAVE_ICONV -DHAVE_INTTYPES_H -DHAVE_PKCRYPT -DHAVE_STDINT_H -DHAVE_WZAES -DHAVE_ZLIB -DZLIB_COMPAT

ApolloReborn_BUNDLE_RESOURCE_DIRS = resources

# Temporary theme-RE instrumentation (theme builder spike). Opt-in only:
#   APOLLO_THEME_RE=1 scripts/run-in-sim.sh
ifeq ($(APOLLO_THEME_RE),1)
ApolloReborn_FILES += $(SRC_DIR)/ApolloThemeRE.xm
ApolloReborn_CFLAGS += -DAPOLLO_THEME_RE=1
endif

# Simulator/dev builds (APOLLO_SIM_BUILD=1; see scripts/run-in-sim.sh) trim the
# device-only pieces so the tweak links and loads against the iOS simulator SDK:
#   - FFmpegKit's static libs are device-arm64 only and won't link for the
#     simulator slice, so we skip them. ApolloMedia.xm stubs the v.redd.it CMAF
#     audio fix under this macro (the only FFmpeg consumer).
#   - The FLEX + openin-extension subprojects are device-oriented and not needed
#     to exercise the tweak in the simulator.
# run-in-sim.sh additionally builds with LOGOS_DEFAULT_GENERATOR=internal so the
# dylib uses ObjC-runtime swizzling and has no CydiaSubstrate dependency.
ifeq ($(APOLLO_SIM_BUILD),1)
# The internal Logos generator does not auto-include <substrate.h> the way the
# MobileSubstrate generator does, so force-include it for the MSHookIvar template
# (a pure ObjC-runtime helper with no CydiaSubstrate link dependency).
ApolloReborn_CFLAGS += -DAPOLLO_SIM_BUILD=1 -include substrate.h
else
ApolloReborn_OBJ_FILES = $(shell find $(FFMPEG_KIT_DIR) -name '*.a')

SUBPROJECTS += $(FLEXING_DIR)/libflex
# Standalone dylib for Apollo's "Open in Apollo" Action extension. Built as a
# LIBRARY (no Substrate/injection plist) into openin-extension/.theos/obj; staged
# into the appex at package time by scripts/fix-openin-extension.sh, NOT injected
# into the main app (see scripts/inject-deb-local.sh).
SUBPROJECTS += openin-extension
endif

CONTROL_FILE = $(THEOS_PROJECT_DIR)/control

# Generate Version.h
before-all:: generate_version_h

generate_version_h:
	@echo "Generating Version.h from control file"
	@version=$$(grep '^Version:' $(CONTROL_FILE) | cut -d' ' -f2); \
	mkdir -p $(THEOS_PROJECT_DIR)/$(SRC_DIR); \
	echo "#define TWEAK_VERSION \"v$${version}\"" > $(THEOS_PROJECT_DIR)/$(SRC_DIR)/Version.h

# Liquid Glass icon metadata header is generated explicitly by running 'make lg-previews'
LG_DIR = $(THEOS_PROJECT_DIR)/liquid-glass
LG_PREVIEW_HEADER = $(LG_DIR)/generated/LiquidGlassIconPreviews.gen.h

.PHONY: lg-previews
lg-previews:
	@echo "Regenerating $(notdir $(LG_PREVIEW_HEADER)) from liquid-glass/icons.json"
	@python3 $(LG_DIR)/scripts/generate_previews_header.py $(LG_PREVIEW_HEADER)

# Move libflex into bundle for rootless deb builds
#   Remove libflex.plist for all packages since it's not needed
before-package::
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	@mv $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/libflex.dylib $(THEOS_STAGING_DIR)/Library/Application\ Support/ApolloReborn/ApolloReborn.bundle/libflex.dylib
endif
	@rm $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/libflex.plist

include $(THEOS_MAKE_PATH)/aggregate.mk
include $(THEOS_MAKE_PATH)/tweak.mk
