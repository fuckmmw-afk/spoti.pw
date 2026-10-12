TARGET := iphone:clang:16.5:16.0
ARCHS := arm64
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := chromajdsp
chromajdsp_FILES := $(shell find Sources -name '*.m')
chromajdsp_CFLAGS := -fobjc-arc -ISources -Ivendor/libjamesdsp/subtree/Main/libjamesdsp/jni/jamesdsp/jdsp -Ivendor/libjamesdsp
chromajdsp_FRAMEWORKS := Foundation AudioToolbox
chromajdsp_OBJ_FILES := vendor/libjamesdsp/build/ios/libjamesdsp.a
chromajdsp_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk

chromajdsp.all.tweak.variables: vendor/libjamesdsp/build/ios/libjamesdsp.a

vendor/libjamesdsp/build/ios/libjamesdsp.a:
	$(MAKE) --no-print-directory -C vendor/libjamesdsp JDSP_PLATFORM=ios
