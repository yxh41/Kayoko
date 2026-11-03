BUNDLE_NAME += KayokoPreferences

KayokoPreferences_USE_MODULES := 0

KayokoPreferences_FILES += $(wildcard Controllers/*.m Cells/*.m Utilities/*.m)
KayokoPreferences_FILES += $(wildcard ../Shared/Tags/*.m)
KayokoPreferences_FILES += $(wildcard ../Shared/Purchases/*.m)

# The script model, store and runner are shared with the tweak: this page is the only way to manage
# scripts.plist, and it has to read, write and dry-run exactly what the panel consumes. They are compiled
# into both binaries rather than linked, because the Settings bundle never loads KayokoCore.
KayokoPreferences_FILES += ../Tweak/Core/Models/KayokoScript.m
KayokoPreferences_FILES += ../Tweak/Core/Models/KayokoScriptResources.m
KayokoPreferences_FILES += ../Tweak/Core/Models/KayokoScriptStore.m
KayokoPreferences_FILES += ../Tweak/Core/Models/KayokoScriptFailure.m
KayokoPreferences_FILES += ../Tweak/Core/Actions/KayokoScriptRunner.m

KayokoPreferences_CFLAGS += -fobjc-arc
KayokoPreferences_CFLAGS += -I.
KayokoPreferences_CFLAGS += -I../Preferences
KayokoPreferences_CFLAGS += -IControllers
KayokoPreferences_CFLAGS += -ICells
KayokoPreferences_CFLAGS += -IUtilities
KayokoPreferences_CFLAGS += -I../Shared/Tags
KayokoPreferences_CFLAGS += -I../Shared/Purchases
KayokoPreferences_CFLAGS += -I../Tweak/Core/Models
KayokoPreferences_CFLAGS += -I../Tweak/Core/Actions

KayokoPreferences_FRAMEWORKS += CoreGraphics
KayokoPreferences_FRAMEWORKS += QuartzCore
KayokoPreferences_FRAMEWORKS += Security
KayokoPreferences_FRAMEWORKS += UIKit

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
KayokoPreferences_CFLAGS += -FFrameworks/_rootless
KayokoPreferences_LDFLAGS += -FFrameworks/_rootless
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
KayokoPreferences_CFLAGS += -FFrameworks/_roothide
KayokoPreferences_LDFLAGS += -FFrameworks/_roothide
else
KayokoPreferences_CFLAGS += -FFrameworks
KayokoPreferences_LDFLAGS += -FFrameworks
endif

KayokoPreferences_EXTRA_FRAMEWORKS += AltList
KayokoPreferences_PRIVATE_FRAMEWORKS += FrontBoardServices
KayokoPreferences_PRIVATE_FRAMEWORKS += Preferences
KayokoPreferences_PRIVATE_FRAMEWORKS += SpringBoardServices

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
KayokoPreferences_LIBRARIES += roothide
endif

KayokoPreferences_INSTALL_PATH := /Library/PreferenceBundles

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
