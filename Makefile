TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

# LIBRARY_NAME (а не TWEAK_NAME), чтобы dylib не тянул CydiaSubstrate
# и работал без джейлбрейка.
LIBRARY_NAME = MyMenu

IMGUI = imgui

MyMenu_FILES = main.mm \
	$(IMGUI)/imgui.cpp \
	$(IMGUI)/imgui_draw.cpp \
	$(IMGUI)/imgui_tables.cpp \
	$(IMGUI)/imgui_widgets.cpp \
	$(IMGUI)/imgui_demo.cpp \
	$(IMGUI)/backends/imgui_impl_metal.mm

MyMenu_CFLAGS = -fobjc-arc -std=c++17 -I$(IMGUI) -I$(IMGUI)/backends \
	-Wno-deprecated-declarations -Wno-unused-variable \
	-Wno-unknown-warning-option -Wno-uninitialized-const-pointer -Wno-error
MyMenu_CCFLAGS = -std=c++17
MyMenu_FRAMEWORKS = UIKit Foundation Metal MetalKit QuartzCore

include $(THEOS_MAKE_PATH)/library.mk
