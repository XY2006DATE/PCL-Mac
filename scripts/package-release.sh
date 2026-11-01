#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
zsh scripts/build-app.sh --universal

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
output_dir="$project_dir/.build/release.noindex"
mkdir -p "$output_dir"
staging=$(mktemp -d "${TMPDIR%/}/pcl-release.XXXXXX")
trap 'rm -rf "$staging"' EXIT

app="$staging/PCL Mac版.app"
ditto ".build/dist.noindex/PCL Mac版.app" "$app"
cp NOTICE "$app/Contents/Resources/NOTICE"
# Remove linker debug entries that retain absolute object-file paths.
strip -S "$app/Contents/MacOS/PCL-SwiftUI"
identity="${PCL_RELEASE_SIGN_IDENTITY:--}"
if [[ "$identity" == '-' ]]; then
  codesign --force --deep --sign - "$app"
  signing_note='此安装包使用本地临时签名，未经 Apple 公证。'
else
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
  signing_note='此安装包使用 Developer ID 签名，未经 Apple 公证。'
fi
codesign --verify --deep --strict "$app"
architectures="$(lipo -archs "$app/Contents/MacOS/PCL-SwiftUI")"
for architecture in arm64 x86_64; do
  if [[ " $architectures " != *" $architecture "* ]]; then
    print -u2 "Missing required architecture: $architecture"
    exit 1
  fi
done

archive_name="PCL-Mac-$version-universal"
zip_path="$output_dir/$archive_name.zip"
dmg_path="$output_dir/$archive_name.dmg"
ditto -c -k --keepParent "$app" "$zip_path"

if [[ -n "${PCL_NOTARY_PROFILE:-}" ]]; then
  if [[ "$identity" == '-' ]]; then
    print -u2 'Notarization requires a Developer ID signing identity.'
    exit 2
  fi
  xcrun notarytool submit "$zip_path" --keychain-profile "$PCL_NOTARY_PROFILE" --wait --timeout 20m
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  signing_note='此安装包已使用 Developer ID 签名并通过 Apple 公证。'
  # ZIP must include the stapled application, not the pre-submission copy.
  rm -f "$zip_path"
  ditto -c -k --keepParent "$app" "$zip_path"
fi

ln -s /Applications "$staging/Applications"
cat > "$staging/安装说明.txt" <<EOF
PCL Mac版 $version（build $build）

将“PCL Mac版.app”拖到“Applications（应用程序）”后启动。
要求 macOS 14 或更新版本，兼容 Apple Silicon 和 Intel。
游戏需要自行安装匹配 Minecraft 版本与架构的 Java。

$signing_note
若首次打开被系统拦截，请先确认安装包来自以下仓库，核对 SHA-256，
再根据 Apple 官方说明，在尝试打开后进入“系统设置 → 隐私与安全性 → 仍要打开”。
https://support.apple.com/zh-cn/102445

下载与源码：https://github.com/XY2006DATE/PCL-Mac
原作者：龙腾猫跃；这是第三方独立 SwiftUI 重构，非官方 macOS 版本。
原许可与来源说明位于应用内 Contents/Resources/LICENCE 和 NOTICE。
EOF
hdiutil create -quiet -volname "PCL Mac版 $version" -srcfolder "$staging" -format UDZO -ov "$dmg_path"
if [[ "$identity" != '-' ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg_path"
fi
if [[ -n "${PCL_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$dmg_path" --keychain-profile "$PCL_NOTARY_PROFILE" --wait --timeout 20m
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi
hdiutil verify "$dmg_path"
(
  cd "$output_dir"
  shasum -a 256 "$archive_name.dmg" "$archive_name.zip" > SHA256SUMS.txt
)
print "Release artifacts: $output_dir"
