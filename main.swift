// 入口：参数解析 + 分发。
//
// 单独放一个 main.swift：Swift 只允许「主文件」写顶层语句，
// 编译多个文件时那个文件必须叫 main.swift（否则报
// "statements are not allowed at the top level"）。
import Foundation

// 不带参数时两个功能都开，方便手动调试；守护脚本总是显式传两个开关
var wantsPanel = CommandLine.arguments.count == 1
var wantsTap = CommandLine.arguments.count == 1
var wantsMenuBar = CommandLine.arguments.count == 1
var wantsNoFinder = CommandLine.arguments.count == 1
var wantsDockWhite = CommandLine.arguments.count == 1
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--panel=1": wantsPanel = true
    case "--panel=0": wantsPanel = false
    case "--tap=1": wantsTap = true
    case "--tap=0": wantsTap = false
    case "--menubar=1": wantsMenuBar = true
    case "--menubar=0": wantsMenuBar = false
    case "--nofinder=1": wantsNoFinder = true
    case "--nofinder=0": wantsNoFinder = false
    case "--dockwhite=1": wantsDockWhite = true
    case "--dockwhite=0": wantsDockWhite = false
    case "help", "-h", "--help": usageAndExit(0)
    default: usageAndExit(2)
    }
}

if wantsPanel || wantsTap || wantsMenuBar || wantsNoFinder || wantsDockWhite {
    runHelper()
}
