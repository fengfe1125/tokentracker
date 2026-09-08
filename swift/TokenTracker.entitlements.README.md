# TokenTracker.entitlements

只有一条 `com.apple.security.automation.apple-events`。

「在终端继续」通过 `osascript` 向 Terminal / iTerm 发 AppleEvent。
`scripts/release_swift.sh` 用 `--options runtime` 开了 hardened runtime，
没有这条 entitlement 的话 AppleEvent 会被直接拒（errAEEventNotPermitted / -1743），
osascript 非 0 退出，UI 上表现为「终端打开失败，命令已复制到剪贴板」。
走 `open -na` 的 WezTerm / Ghostty 不需要授权，所以旧版是「有时」失败。

必须与 Info.plist 里的 `NSAppleEventsUsageDescription` 成对出现，缺一不可
（前者管 hardened runtime，后者管 TCC 弹窗；少了 usage string 系统连框都不弹）。

⚠️ 这个文件里不能写 XML 注释：`plutil -lint` 会放行，但 codesign 的 AMFI
解析器会报 `AMFIUnserializeXML: syntax error`，签名直接失败。
