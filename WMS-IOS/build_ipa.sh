
#!/bin/bash

set -e

# 项目配置
PROJECT_NAME="WMSStockOutiOS"
SCHEME="WMSStockOutiOS"
CONFIGURATION="Release"

# 自动定位项目文件
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT=$(find "$ROOT" -maxdepth 3 -name "*.xcodeproj" -print -quit)

if [ -z "$PROJECT" ]; then
    echo "❌ 找不到 Xcode 项目文件"
    exit 1
fi

echo "================================"
echo "       WMS IPA 自动打包"
echo "================================"

echo "项目路径：$PROJECT"
echo "正在清理旧编译文件..."

BUILD_DIR="$ROOT/IPA_Build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 编译 Release
echo "正在编译 iOS Release..."

xcodebuild \
-project "$PROJECT" \
-scheme "$SCHEME" \
-configuration "$CONFIGURATION" \
-sdk iphoneos \
-destination 'generic/platform=iOS' \
-derivedDataPath "$BUILD_DIR/DerivedData" \
CODE_SIGNING_ALLOWED=NO \
CODE_SIGNING_REQUIRED=NO \
CODE_SIGN_IDENTITY="" \
clean build

# 定位 APP
APP_PATH=$(find "$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos" \
-maxdepth 1 -name "*.app" -print -quit)

if [ -z "$APP_PATH" ]; then
    echo "❌ 没有找到编译生成的 APP"
    exit 1
fi

echo "APP 编译成功：$APP_PATH"

# 创建 IPA 目录
mkdir -p "$BUILD_DIR/Payload"

cp -R "$APP_PATH" "$BUILD_DIR/Payload/"

# 固化应用图标 (App Icon 固化注入)
ICON_SRC="$ROOT/WMS 1.0/AppIcons"
if [ -d "$ICON_SRC" ]; then
    echo "正在注入固化应用图标..."
    cp -f "$ICON_SRC"/* "$BUILD_DIR/Payload/WMSStockOutiOS.app/"
fi

# 打包 IPA
cd "$BUILD_DIR"

/usr/bin/zip -qry WMSStockOutiOS.ipa Payload

echo "================================"
echo "       IPA 打包成功！"
echo "================================"

echo "文件位置："
echo "$BUILD_DIR/WMSStockOutiOS.ipa"

open "$BUILD_DIR"

