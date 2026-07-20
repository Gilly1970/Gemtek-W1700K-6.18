# This is free software, licensed under the Apache License, Version 2.0 .

include $(TOPDIR)/rules.mk

PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI W1700K Fan Control
LUCI_PKGNAME:=luci-app-w1700k-fancontrol
LUCI_DEPENDS:=+luci-base @TARGET_airoha

include ../../luci.mk

define Package/luci-app-w1700k-fancontrol/conffiles
/etc/config/fan
endef

# call BuildPackage - OpenWrt buildroot signature
