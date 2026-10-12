TARGET := iphone:clang:16.5:16.0
ARCHS := arm64
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := aispatial
aispatial_FILES := $(shell find Sources \( -name '*.m' -o -name '*.c' \))
aispatial_CFLAGS := -fobjc-arc -ISources
aispatial_FRAMEWORKS := Foundation UIKit CoreML AVFoundation Accelerate AudioToolbox MediaPlayer
aispatial_LIBRARIES := z
aispatial_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk

# Host-side checks cover the lock-free stream core without requiring Core ML or
# an Apple runtime.  They are intentionally separate from the arm64 tweak build
# and are run by GitHub Actions before packaging.
.PHONY: test
test:
	@mkdir -p .theos/host-tests
	@clang -std=c11 -D_GNU_SOURCE -I Sources Sources/AISpatialStreamCore.c Tests/AISpatialStreamCoreTests.c -lm -o .theos/host-tests/AISpatialStreamCoreTests
	@.theos/host-tests/AISpatialStreamCoreTests
	@clang -std=c11 -D_GNU_SOURCE -I Sources Sources/AISpatialAccentCore.c Tests/AISpatialAccentCoreTests.c -lm -o .theos/host-tests/AISpatialAccentCoreTests
	@.theos/host-tests/AISpatialAccentCoreTests
