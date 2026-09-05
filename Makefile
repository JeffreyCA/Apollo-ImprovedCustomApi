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
THEME_GALLERY_DIR := theme-gallery
THEME_GALLERY_GEN_H := $(THEOS_PROJECT_DIR)/$(THEME_GALLERY_DIR)/generated/ApolloThemeGalleryCatalog.gen.h
THEME_GALLERY_GEN_M := $(THEOS_PROJECT_DIR)/$(THEME_GALLERY_DIR)/generated/ApolloThemeGalleryCatalog.gen.m
WHATS_NEW_DIR := whats-new
WHATS_NEW_GEN_H := $(THEOS_PROJECT_DIR)/$(WHATS_NEW_DIR)/generated/ApolloWhatsNewCatalog.gen.h
WHATS_NEW_GEN_M := $(THEOS_PROJECT_DIR)/$(WHATS_NEW_DIR)/generated/ApolloWhatsNewCatalog.gen.m

SSZIPARCHIVE_FILES = $(wildcard $(SSZIPARCHIVE_DIR)/*.m) \
    $(wildcard $(SSZIPARCHIVE_DIR)/minizip/*.c) \
    $(wildcard $(SSZIPARCHIVE_DIR)/minizip/compat/*.c)

# KSCrash local crash recording (src/crash/). Only the recording layer is
# compiled — Core, RecordingCore, Recording — never the Sinks/Installations/
# Filters/BootTime/DiscSpace modules, so the library has no reporting or
# transmission capability at all. Pinned via the modules/KSCrash submodule
# (2.5.1); the explicit per-module find below cannot pick up sources from
# modules an upstream bump might add.
KSCRASH_DIR := $(MODULES_DIR)/KSCrash
KSCRASH_CORE_DIR := $(KSCRASH_DIR)/Sources/KSCrashCore
KSCRASH_RECORDING_CORE_DIR := $(KSCRASH_DIR)/Sources/KSCrashRecordingCore
KSCRASH_RECORDING_DIR := $(KSCRASH_DIR)/Sources/KSCrashRecording

KSCRASH_FILES := \
    $(shell find $(KSCRASH_CORE_DIR) $(KSCRASH_RECORDING_CORE_DIR) $(KSCRASH_RECORDING_DIR) \
        -type f \( -name '*.c' -o -name '*.m' -o -name '*.mm' -o -name '*.cpp' \) | sort)

ApolloReborn_FILES = \
    $(SRC_DIR)/ApolloFoundationModels.swift \
    $(SRC_DIR)/ApolloAISummary.xm \
    $(SRC_DIR)/ApolloAICloudBridge.m \
    $(SRC_DIR)/ApolloAutoHideMetaFeeds.xm \
    $(SRC_DIR)/ApolloDevvitPosts.xm \
    $(SRC_DIR)/ApolloWhatsNew.xm \
    $(WHATS_NEW_GEN_M) \
    $(SRC_DIR)/Tweak.xm \
    $(SRC_DIR)/ApolloCommon.m \
    $(SRC_DIR)/ApolloWebTextDecoding.m \
    $(SRC_DIR)/ApolloMemoryDiagnostics.m \
    $(SRC_DIR)/settings/ApolloSettingsTableViewController.m \
    $(SRC_DIR)/settings/ApolloSettingsForm.m \
    $(SRC_DIR)/settings/ApolloSettingsPinnedPreview.m \
    $(SRC_DIR)/settings/ApolloContributors.m \
    $(SRC_DIR)/settings/ApolloBackupRestore.m \
    $(SRC_DIR)/settings/ApolloThanksToViewController.m \
    $(SRC_DIR)/settings/ApolloBuyUsACoffeeViewController.m \
    $(SRC_DIR)/settings/ApolloWallpaperViewerViewController.m \
    $(SRC_DIR)/settings/ApolloWallpapersViewController.m \
    $(SRC_DIR)/settings/ApolloReportViewController.m \
    $(SRC_DIR)/settings/ApolloSettingsRouter.m \
    $(SRC_DIR)/settings/ApolloSettingsSearch.m \
    $(SRC_DIR)/ApolloToast.m \
    $(SRC_DIR)/ApolloRedditMediaUpload.m \
    $(SRC_DIR)/ApolloNotificationBackend.m \
    $(SRC_DIR)/ApolloUsageHeartbeat.m \
    $(SRC_DIR)/ApolloPushNotifications.m \
    $(SRC_DIR)/ApolloLiquidGlassIconIDs.m \
    $(SRC_DIR)/ApolloBarkNotifications.m \
    $(SRC_DIR)/ApolloChatUnreadPoller.m \
    $(SRC_DIR)/ApolloChatRoomDirectory.m \
    $(SRC_DIR)/ApolloUserProfileCache.m \
    $(SRC_DIR)/ApolloSubredditInfoCache.m \
    $(SRC_DIR)/ApolloSubredditCustomBannerCache.m \
    $(SRC_DIR)/ApolloSubredditCustomIconCache.m \
    $(SRC_DIR)/ApolloSubredditDefaultAssets.c \
    $(SRC_DIR)/ApolloImmersiveHeaderBackground.m \
    $(SRC_DIR)/ApolloIdentityHeaderLayout.m \
    $(SRC_DIR)/ApolloUserAvatars.xm \
    $(SRC_DIR)/ApolloScrapeWebView.m \
    $(SRC_DIR)/ApolloProfileSocialLinks.m \
    $(SRC_DIR)/ApolloBadgeBookCatalog.m \
    $(SRC_DIR)/ApolloBadgeBookScraper.m \
    $(SRC_DIR)/ApolloBadgeBookViewController.m \
    $(SRC_DIR)/ApolloBadgeBookStrip.m \
    $(SRC_DIR)/ApolloModeratorAvatars.xm \
    $(SRC_DIR)/ApolloPublicStickyAsSubreddit.xm \
    $(SRC_DIR)/ApolloSubredditHeaders.xm \
    $(SRC_DIR)/ApolloSubredditHighlights.xm \
    $(SRC_DIR)/ApolloGalleryFeed.m \
    $(SRC_DIR)/ApolloGalleryImageLoader.m \
    $(SRC_DIR)/ApolloGalleryImageViewer.m \
    $(SRC_DIR)/ApolloGalleryViewController.m \
    $(SRC_DIR)/ApolloGalleryVideoExport.xm \
    $(SRC_DIR)/ApolloGalleryMenu.xm \
    $(SRC_DIR)/ApolloGalleryOrientation.xm \
    $(SRC_DIR)/ApolloBannedProfile.xm \
    $(SRC_DIR)/ApolloImageUploadHost.xm \
    $(SRC_DIR)/ApolloPhotoPostComposerScrollFix.xm \
    $(SRC_DIR)/ApolloMarkdownToolbarGif.xm \
    $(SRC_DIR)/ApolloComposerToolbarTint.xm \
    $(SRC_DIR)/ApolloMarkdownBodyCleanup.xm \
    $(SRC_DIR)/ApolloGiphyClient.m \
    $(SRC_DIR)/GiphyPickerViewController.m \
    $(SRC_DIR)/ApolloCommentVoteInsights.m \
    $(SRC_DIR)/ApolloCreatedAtAlert.xm \
    $(SRC_DIR)/ApolloDeletedCommentsData.m \
    $(SRC_DIR)/ApolloDeletedCommentsUI.xm \
    $(SRC_DIR)/ApolloDeletedCommentsMenu.xm \
    $(SRC_DIR)/ApolloState.m \
    $(SRC_DIR)/ApolloShareLinks.xm \
    $(SRC_DIR)/ApolloMedia.xm \
    $(SRC_DIR)/ApolloFeedGalleryCarousel.xm \
    $(SRC_DIR)/ApolloSwipeUpComments.xm \
    $(SRC_DIR)/ApolloMediaMetadata.m \
    $(SRC_DIR)/ApolloMediaAutoplay.m \
    $(SRC_DIR)/ApolloCommentsCollapse.xm \
    $(SRC_DIR)/ApolloInboxCommentScroll.xm \
    $(SRC_DIR)/ApolloFindInComments.xm \
    $(SRC_DIR)/ApolloStatsRowTouch.xm \
    $(SRC_DIR)/ApolloCommentVoteFlicker.xm \
    $(SRC_DIR)/ApolloLiveCommentsFollow.xm \
    $(SRC_DIR)/settings/ApolloSettingsGeneralTable.xm \
    $(SRC_DIR)/settings/ApolloSettingsNativeInjections.xm \
    $(SRC_DIR)/ApolloPerPostCommentSort.xm \
    $(SRC_DIR)/ApolloLiquidGlass.xm \
    $(SRC_DIR)/ApolloTabBarTitles.xm \
    $(SRC_DIR)/ApolloScrollEdgePopFix.xm \
    $(SRC_DIR)/ApolloInterruptibleNavTransition.xm \
    $(SRC_DIR)/ApolloLiquidGlassIconPicker.xm \
    $(SRC_DIR)/ApolloModmailLayout.xm \
    $(SRC_DIR)/ApolloModmailSubjectCounter.xm \
    $(SRC_DIR)/ApolloAutoHideTabBar.xm \
    $(SRC_DIR)/ApolloListBottomInsetGuard.xm \
    $(SRC_DIR)/ApolloTabBarHideStyle.xm \
    $(SRC_DIR)/ApolloIPadTabBarBottom.xm \
    $(SRC_DIR)/ApolloScrollEdgeEffect.xm \
    $(SRC_DIR)/ApolloProgressiveBlur.xm \
    $(SRC_DIR)/settings/ApolloSettings.xm \
    $(SRC_DIR)/ApolloRecentlyRead.xm \
    $(SRC_DIR)/ApolloProfileMoreMenu.xm \
    $(SRC_DIR)/ApolloHiddenContentData.m \
    $(SRC_DIR)/ApolloHiddenContentViewController.m \
    $(SRC_DIR)/ApolloHiddenContentMenu.xm \
    $(SRC_DIR)/ApolloHideLinksBatchFix.xm \
    $(SRC_DIR)/ApolloSavedItemsDeduplicator.m \
    $(SRC_DIR)/ApolloSavedCategories.xm \
    $(SRC_DIR)/ApolloSwiftIvarBridge.swift \
    $(SRC_DIR)/ApolloUserFlair.xm \
    $(SRC_DIR)/ApolloOwnCommentFlair.xm \
    $(SRC_DIR)/ApolloFlairColors.xm \
    $(SRC_DIR)/ApolloNativeActionMenus.xm \
    $(SRC_DIR)/ApolloContextMenuPreviewTheme.xm \
    $(SRC_DIR)/ApolloActionMenu.xm \
    $(SRC_DIR)/ApolloHostedVideo.m \
    $(SRC_DIR)/ApolloSportsClipResolver.m \
    $(SRC_DIR)/ApolloSportsClips.xm \
    $(SRC_DIR)/ApolloRedgifsSubdomainFix.xm \
    $(SRC_DIR)/ApolloShareAsImageGallery.xm \
    $(SRC_DIR)/ApolloShareAsImageLink.xm \
    $(SRC_DIR)/ApolloShareAsVideo.xm \
    $(SRC_DIR)/ApolloShareAsImagePreviewFix.xm \
    $(SRC_DIR)/ApolloTranslation.xm \
    $(SRC_DIR)/ApolloAppleTranslation.swift \
    $(SRC_DIR)/ApolloAppleTranslateSheet.swift \
    $(SRC_DIR)/ApolloAppleTranslateSheet.xm \
    $(SRC_DIR)/ApolloVideoUnmute.xm \
    $(SRC_DIR)/ApolloFeedVideoScrubber.xm \
    $(SRC_DIR)/ApolloForwardSwipeExpiry.xm \
    $(SRC_DIR)/ApolloVideoSwipeFix.xm \
    $(SRC_DIR)/ApolloVideoPlaybackSpeed.xm \
    $(SRC_DIR)/ApolloVideoHoldSpeed.xm \
    $(SRC_DIR)/ApolloPictureInPicture.xm \
    $(SRC_DIR)/ApolloFloatingTabs.xm \
    $(SRC_DIR)/ApolloMediaPreviewErrorFix.xm \
    $(SRC_DIR)/ApolloFeedShortcutsAppearance.m \
    $(SRC_DIR)/ApolloSubredditIndexPolish.xm \
    $(SRC_DIR)/ApolloSubredditListLaunchSettle.xm \
    $(SRC_DIR)/ApolloQuickActions.xm \
    $(SRC_DIR)/ApolloHideModSubreddits.xm \
    $(SRC_DIR)/ApolloMultiredditEdit.xm \
    $(SRC_DIR)/ApolloFollowingSection.xm \
    $(SRC_DIR)/ApolloSubredditSidebar.xm \
    $(SRC_DIR)/ApolloTagFilters.xm \
    $(SRC_DIR)/ApolloThemeTokens.m \
    $(SRC_DIR)/ApolloThemeCompiler.m \
    $(SRC_DIR)/ApolloThemeStore.m \
    $(SRC_DIR)/ApolloThemeGalleryCatalog.m \
    $(THEME_GALLERY_GEN_M) \
    $(SRC_DIR)/ApolloThemeRuntime.xm \
    $(SRC_DIR)/ApolloThemeHCT.c \
    $(SRC_DIR)/ApolloThemePaletteEngine.m \
    $(SRC_DIR)/ApolloThemeAI.m \
    $(SRC_DIR)/ApolloThemeAISheets.m \
    $(SRC_DIR)/ApolloThemeAIOverlay.m \
    $(SRC_DIR)/ApolloThemeManagerViewController.m \
    $(SRC_DIR)/ApolloThemeGalleryViewController.m \
    $(SRC_DIR)/ApolloThemeManagerIntegration.xm \
    $(SRC_DIR)/ApolloThemeIntegrations.xm \
    $(SRC_DIR)/ApolloThemeShareImage.m \
    $(SRC_DIR)/ApolloThemeQRScanViewController.m \
    $(SRC_DIR)/ApolloSearchInPlace.xm \
    $(SRC_DIR)/ApolloSearchNativeBar.xm \
    $(SRC_DIR)/ApolloSearchObserverCleanup.xm \
    $(SRC_DIR)/ApolloJumpBarSuggestionTint.xm \
    $(SRC_DIR)/ApolloSearchHeaderOverlapFix.xm \
    $(SRC_DIR)/ApolloSearchTabFixes.xm \
    $(SRC_DIR)/ApolloImageChestResolver.m \
    $(SRC_DIR)/ApolloImgChestUpload.m \
    $(SRC_DIR)/ApolloLinkPreviewModel.m \
    $(SRC_DIR)/ApolloLinkPreviewCache.m \
    $(SRC_DIR)/ApolloLinkPreviewShapeMemory.m \
    $(SRC_DIR)/ApolloLinkPreviewFetcher.m \
    $(SRC_DIR)/ApolloInlineImages.xm \
    $(SRC_DIR)/ApolloInlineLinkPreviews.xm \
    $(SRC_DIR)/ApolloChatInlineImages.xm \
    $(SRC_DIR)/ApolloChatComposer.xm \
    $(SRC_DIR)/ApolloChatsFilter.xm \
    $(SRC_DIR)/ApolloDirectChatWeb.xm \
    $(SRC_DIR)/ApolloLinkCardTitleFallback.xm \
    $(SRC_DIR)/ApolloFeedTextPostThumbnails.xm \
    $(SRC_DIR)/ApolloTweetBuddy.xm \
	$(SRC_DIR)/ApolloVisionOSFix.xm \
    $(SRC_DIR)/ApolloVisionOSHover.xm \
    $(SRC_DIR)/ApolloVisionOSMultiwindow.xm \
    $(SRC_DIR)/ApolloWebAuthViewController.m \
    $(SRC_DIR)/ApolloWebJSON.m \
    $(SRC_DIR)/ApolloWebJSONIdentity.xm \
    $(SRC_DIR)/ApolloWebSessionLoginViewController.m \
    $(SRC_DIR)/ApolloWebSessionStore.m \
    $(SRC_DIR)/ApolloPollVoting.xm \
    $(SRC_DIR)/ApolloPollCompose.xm \
    $(SRC_DIR)/settings/ApolloPollSettingsViewController.m \
    $(SRC_DIR)/ApolloSimDebugTap.xm \
    $(SRC_DIR)/ApolloManualSignInViewController.m \
    $(SRC_DIR)/ApolloAccountCredentials.m \
    $(SRC_DIR)/ApolloPerAccountFavorites.m \
    $(SRC_DIR)/ApolloAccountSwitcherViewController.xm \
    $(SRC_DIR)/ApolloSignInSplash.xm \
    $(SRC_DIR)/ApolloHideSubscribePrompt.xm \
    $(SRC_DIR)/settings/CustomAPIViewController.m \
    $(SRC_DIR)/settings/ApolloSubredditLayoutViewController.m \
    $(SRC_DIR)/settings/ApolloSubredditSectionsViewController.m \
    $(SRC_DIR)/settings/ApolloAISettingsViewController.m \
    $(SRC_DIR)/settings/ApolloDeletedCommentsSettingsViewController.m \
    $(SRC_DIR)/settings/ApolloProfileLayoutViewController.m \
    $(SRC_DIR)/settings/ApolloLinkPreviewSettingsViewController.m \
    $(SRC_DIR)/settings/InlineMediaSettingsViewController.m \
    $(SRC_DIR)/settings/InfoRowSettingsViewController.m \
    $(SRC_DIR)/settings/ApolloOpenInAppViewController.m \
    $(SRC_DIR)/settings/ApolloLinkCompanionViewController.m \
    $(SRC_DIR)/settings/ApolloLinkCompanionIconData.m \
    $(SRC_DIR)/settings/TranslationSettingsViewController.m \
    $(SRC_DIR)/settings/SavedCategoriesViewController.m \
    $(SRC_DIR)/TagFiltersViewController.m \
    $(SRC_DIR)/ApolloPostFilterStore.m \
    $(SRC_DIR)/ApolloPostFilters.xm \
    $(SRC_DIR)/ApolloFiltersBlocksInject.xm \
    $(SRC_DIR)/ApolloSubredditFilterDetailViewController.m \
    $(SRC_DIR)/PictureInPictureViewController.m \
    $(SRC_DIR)/Defaults.m \
    $(SRC_DIR)/UIWindow+Apollo.m \
    $(SRC_DIR)/fishhook.c \
    $(SRC_DIR)/crash/ApolloCrashManager.m \
    $(SRC_DIR)/crash/ApolloCrashContext.m \
    $(SRC_DIR)/crash/ApolloCrashSanitizer.m \
    $(SRC_DIR)/crash/ApolloCrashAttachment.m \
    $(SRC_DIR)/crash/ApolloCrashPromptCoordinator.m \
    $(SRC_DIR)/crash/ApolloCrashReviewViewController.m \
    $(SRC_DIR)/crash/ApolloCrashReportsViewController.m \
    $(SRC_DIR)/crash/ApolloCrashBugsnagNeutralize.xm \
    $(KSCRASH_FILES) \
    $(SSZIPARCHIVE_FILES)
ApolloReborn_FRAMEWORKS = UIKit Security AVFoundation AVKit OSLog NaturalLanguage ImageIO StoreKit Photos PhotosUI SafariServices SystemConfiguration WebKit AuthenticationServices CoreImage Vision LinkPresentation SwiftUI UniformTypeIdentifiers Metal QuartzCore CoreMotion
ApolloReborn_LIBRARIES = z iconv
# FoundationModels (Apple on-device AI) only ships in the iOS 26+ SDK. Weak-link
# it so the dylib still loads on older OSes (the Swift bridge guards every call
# behind #available(iOS 26)), but ONLY when the build SDK actually contains the
# framework. Older toolchains — e.g. CI's Xcode 16 / iOS 18 SDK, which predates
# it — would otherwise fail at link with "framework 'FoundationModels' not
# found". On those SDKs `#if canImport(FoundationModels)` is already false, so
# the Swift bridge references no FM symbols and the flag isn't needed (the
# feature simply reports unavailable in that build).
ifneq ($(wildcard $(SYSROOT)/System/Library/Frameworks/FoundationModels.framework),)
ApolloReborn_LDFLAGS += -weak_framework FoundationModels
endif
# FoundationModels' @Generable / @Guide macros are implemented by the
# FoundationModelsMacros compiler plugin, which ships in the iPhoneOS
# *platform* plugin dir — NOT the toolchain's default host/plugins. Because we
# build against the copied SDK in $THEOS/sdks (outside the .platform), swiftc
# doesn't auto-add that path, so the macro can't resolve ("plugin for module
# 'FoundationModelsMacros' not found"). Point swiftc at the platform plugin
# dir explicitly, only when it's present. (Nothing uses the macros right now —
# theme generation moved off guided generation entirely — but the flag is
# harmless and any future @Generable use silently needs it.)
FM_PLUGIN_PATH := $(shell xcode-select -p)/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins
ifneq ($(wildcard $(FM_PLUGIN_PATH)/libFoundationModelsMacros.dylib),)
ApolloReborn_SWIFTFLAGS += -plugin-path $(FM_PLUGIN_PATH)
endif
# Apple's Translation framework (used by the on-device "apple" translation provider in
# ApolloAppleTranslation.swift) only exists on iOS 18.0+. Weak-link it so the tweak still
# loads on older iOS, where the Apple provider is gated off at runtime.
ApolloReborn_LDFLAGS += -weak_framework Translation
ApolloReborn_CFLAGS = -fobjc-arc -Wno-error=unguarded-availability-new -Wno-error=deprecated-declarations -Wno-module-import-in-extern-c -I$(THEOS_PROJECT_DIR)/$(SRC_DIR) -I$(THEOS_PROJECT_DIR)/liquid-glass/generated -I$(THEOS_PROJECT_DIR)/$(THEME_GALLERY_DIR)/generated -I$(THEOS_PROJECT_DIR)/$(WHATS_NEW_DIR)/generated -I$(THEOS_PROJECT_DIR)/$(MODULES_DIR) -I$(THEOS_PROJECT_DIR)/$(SSZIPARCHIVE_DIR) -I$(THEOS_PROJECT_DIR)/$(SSZIPARCHIVE_DIR)/minizip -DHAVE_ARC4RANDOM_BUF -DHAVE_ICONV -DHAVE_INTTYPES_H -DHAVE_PKCRYPT -DHAVE_STDINT_H -DHAVE_WZAES -DHAVE_ZLIB -DZLIB_COMPAT

# KSCrash include paths (public `include/` dirs plus module roots for private
# headers and the Monitors subdir). KSCRASH_NAMESPACE suffixes every public
# KSCrash symbol AND ObjC class (KSCrash -> KSCrash_ApolloReborn, via
# KSCrashNamespace.h token pasting), so a second KSCrash copy in the process —
# Apollo's own Bugsnag vendors a fork — can never collide at the symbol level.
# The define is global so the src/crash/ consumers see the same renamed classes.
ApolloReborn_CFLAGS += \
    -I$(THEOS_PROJECT_DIR)/$(KSCRASH_CORE_DIR)/include \
    -I$(THEOS_PROJECT_DIR)/$(KSCRASH_RECORDING_CORE_DIR)/include \
    -I$(THEOS_PROJECT_DIR)/$(KSCRASH_RECORDING_CORE_DIR) \
    -I$(THEOS_PROJECT_DIR)/$(KSCRASH_RECORDING_DIR)/include \
    -I$(THEOS_PROJECT_DIR)/$(KSCRASH_RECORDING_DIR) \
    -I$(THEOS_PROJECT_DIR)/$(KSCRASH_RECORDING_DIR)/Monitors \
    -DKSCRASH_NAMESPACE=_ApolloReborn

# No explicit -std/-fexceptions for KSCrash's C++ sources: clang's defaults
# (gnu++17, exceptions on) already satisfy them, and Theos feeds CCFLAGS to
# the Swift module-interface build, where a C++ -std flag is a hard error.
ApolloReborn_LIBRARIES += c++

ApolloReborn_BUNDLE_RESOURCE_DIRS = resources
ApolloReborn_BUNDLE_RESOURCES = \
    assets/bark-icons/low-battery.png \
    assets/bark-icons/palette.png

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
# Swift sources gate sim-only test plumbing (e.g. the host Apple-translation
# bridge in ApolloAppleTranslation.swift) on the same flag.
ApolloReborn_SWIFTFLAGS += -DAPOLLO_SIM_BUILD
# Xcode 27 sim builds raise DEPLOY_MIN to 15.0 (older targets fail libc++'s
# "no longer supported" check), which turns UIApplication.windows deprecation
# warnings into -Werror failures. Silence them rather than rewriting working
# device-targeted call sites just for the sim build.
ApolloReborn_CFLAGS += -Wno-deprecated-declarations
# Sim-only dev helper: env-gated (APOLLO_OPEN_ROUTE) route opener for hands-off
# screenshots. Only ever compiled into the simulator build, never the device/
# release build (this branch is under the APOLLO_SIM_BUILD ifeq).
ApolloReborn_FILES += $(SRC_DIR)/ApolloSimOpenRoute.m
# Opt-in /api/comment write diagnostics + legacy-response-shape simulator
# (APOLLO_COMMENT_DEBUG=1 scripts/run-in-sim.sh). Used to reproduce Reddit's
# 2026-08 legacy write-response regression against the OAuth path on demand —
# see src/ApolloCommentDebug.xm.
ifeq ($(APOLLO_COMMENT_DEBUG),1)
ApolloReborn_FILES += $(SRC_DIR)/ApolloCommentDebug.xm
endif
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

# Generate Version.h, the theme gallery catalog, and the What's New catalog.
before-all:: generate_version_h generate_theme_gallery_catalog generate_whats_new_catalog

generate_version_h:
	@echo "Generating Version.h from control file"
	@version=$$(grep '^Version:' $(CONTROL_FILE) | cut -d' ' -f2); \
	commit=$$(git -C $(THEOS_PROJECT_DIR) rev-parse --short HEAD 2>/dev/null || echo unknown); \
	mkdir -p $(THEOS_PROJECT_DIR)/$(SRC_DIR); \
	{ echo "#define TWEAK_VERSION \"v$${version}\""; \
	  echo "#define APOLLO_GIT_COMMIT \"$${commit}\""; } > $(THEOS_PROJECT_DIR)/$(SRC_DIR)/Version.h

THEME_GALLERY_SOURCES := $(wildcard $(THEOS_PROJECT_DIR)/$(THEME_GALLERY_DIR)/themes/*.json)

generate_theme_gallery_catalog: $(THEME_GALLERY_GEN_H) $(THEME_GALLERY_GEN_M)

$(THEME_GALLERY_GEN_H) $(THEME_GALLERY_GEN_M): $(THEOS_PROJECT_DIR)/$(THEME_GALLERY_DIR)/scripts/generate_catalog.py $(THEME_GALLERY_SOURCES)
	@python3 $(THEOS_PROJECT_DIR)/$(THEME_GALLERY_DIR)/scripts/generate_catalog.py \
		$(THEOS_PROJECT_DIR)/$(THEME_GALLERY_DIR)/themes \
		$(THEME_GALLERY_GEN_H) \
		$(THEME_GALLERY_GEN_M)

WHATS_NEW_SOURCES := $(wildcard $(THEOS_PROJECT_DIR)/$(WHATS_NEW_DIR)/releases/*.json)

generate_whats_new_catalog: $(WHATS_NEW_GEN_H) $(WHATS_NEW_GEN_M)

$(WHATS_NEW_GEN_H) $(WHATS_NEW_GEN_M): $(THEOS_PROJECT_DIR)/$(WHATS_NEW_DIR)/scripts/generate_catalog.py $(WHATS_NEW_SOURCES)
	@python3 $(THEOS_PROJECT_DIR)/$(WHATS_NEW_DIR)/scripts/generate_catalog.py \
		$(THEOS_PROJECT_DIR)/$(WHATS_NEW_DIR)/releases \
		$(WHATS_NEW_GEN_H) \
		$(WHATS_NEW_GEN_M)

# Liquid Glass icon metadata header is generated explicitly by running 'make lg-previews'
LG_DIR = $(THEOS_PROJECT_DIR)/liquid-glass
LG_PREVIEW_HEADER = $(LG_DIR)/generated/LiquidGlassIconPreviews.gen.h

.PHONY: lg-previews
lg-previews:
	@echo "Regenerating $(notdir $(LG_PREVIEW_HEADER)) from liquid-glass/icons.json"
	@python3 $(LG_DIR)/scripts/generate_previews_header.py $(LG_PREVIEW_HEADER)

# Staged jailbreak resource bundle (holds libflex, PNGs, and the ARVariant
# marker). Space in "Application Support" — always reference it quoted in recipes.
STAGED_APOLLO_BUNDLE = $(THEOS_STAGING_DIR)/Library/Application Support/ApolloReborn/ApolloReborn.bundle

# before-package runs after the bundle is staged but before the .deb is built.
# Three things happen here:
#   - libflex.dylib is moved into the bundle for rootless (its DynamicLibraries
#     home doesn't exist rootless);
#   - libflex.plist is dropped for every scheme (unused);
#   - the usage-heartbeat build variant marker is stamped for jailbreak installs.
#     ApolloBuildVariant() reads ARVariant.txt for .deb installs (there's no
#     repackaged Info.plist to carry ARBuildVariant the way injected IPAs do).
#     Injected IPAs stamp Info.plist at packaging time and check it first, so
#     this file being copied into an IPA's bundle is harmless — the plist key wins.
before-package::
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	@mv $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/libflex.dylib "$(STAGED_APOLLO_BUNDLE)/libflex.dylib"
	@printf 'deb-rootless\n' > "$(STAGED_APOLLO_BUNDLE)/ARVariant.txt"
else
	@printf 'deb-rootful\n' > "$(STAGED_APOLLO_BUNDLE)/ARVariant.txt"
endif
	@rm $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/libflex.plist

include $(THEOS_MAKE_PATH)/aggregate.mk
include $(THEOS_MAKE_PATH)/tweak.mk
