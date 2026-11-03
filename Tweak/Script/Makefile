ARCHS := arm64
TOOL_NAME := kayoko_script

kayoko_script_USE_MODULES := 0

kayoko_script_FILES += main.m

kayoko_script_CFLAGS += -fobjc-arc

kayoko_script_FRAMEWORKS += Foundation
kayoko_script_FRAMEWORKS += JavaScriptCore

kayoko_script_INSTALL_PATH := /usr/local/libexec
kayoko_script_CODESIGN_FLAGS += -Splatformize.entitlements

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk
