import Foundation

// 1.8.18 收尾：十类崩溃原因判读器已移除。
// 前 15 轮的经验结论：App 内探针看不到 NodeMobile / V8 的 C++ 层崩溃，
// 真正管用的是系统 .ips 的线程栈。这里只留一句导出指引。

enum CrashDiagnostic {
    static func lines() -> [String] {
        ["--- 崩溃定位 ---",
         "取证探针已移除；若发生闪退，请导出系统 .ips 崩溃日志：",
         "设置 → 隐私与安全性 → 分析与改进 → 分析数据 → MyTVBox"]
    }
}
