//
//  HeavyWorkGate.swift
//  MyTVBox
//
//  1.8.2：端上 Node 同时只允许跑一件「整站级」重活。
//
//  1.8.1 的轨迹显示崩溃前同时有两件在跑：
//    ① 搜索页的 60 站聚合搜索（15:48:06.822 开 搜索 敦煌英雄 站=60/110）
//    ② 详情页的跨站接管（15:48:03.525 完 详情 无线路 → 紧接着跑接管两轮，
//       第二轮 maxSites 还是 200，等于 110 站）
//  Node 那边每个 spider 都是一次模块执行 + 上游抓取，两件叠一起 V8 堆直接到顶，
//  进程被 abort —— 就是「闪退」。
//
//  设计：只闸「聚合类」重活（跨站搜索 / 跨站接管），单站请求（detail、play）
//  不过闸，避免点开详情还要排在搜索后面。注意**不可重入**：跨站接管内部会调
//  `CrossSiteResolver.search`，所以接管自己不持闸，靠它内部的搜索去排队。
//

import Foundation

actor HeavyWorkGate {

    static let shared = HeavyWorkGate()

    private var busy = false
    private var waiters: [(id: UUID, cont: CheckedContinuation<Bool, Never>)] = []

    /// 拿闸；被取消时返回 false（调用方直接放弃，不要再干活）
    func acquire() async -> Bool {
        if !busy {
            busy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                // 竞态防护：取消可能发生在 append 之前（onCancel 里的 Task 此时
                // 还找不到这个 waiter）。append 前先自查一次，否则这一让就永远醒不过来。
                if Task.isCancelled {
                    cont.resume(returning: false)
                    return
                }
                waiters.append((id, cont))
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
    }

    private func dropWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: i)
        w.cont.resume(returning: false)
    }

    /// 还闸：有排队者就把闸直接交给下一个，busy 保持 true
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            let w = waiters.removeFirst()
            w.cont.resume(returning: true)
        }
    }

    /// 排队 → 执行 → 必然还闸。取消时返回 nil。
    func run<T>(_ body: @escaping () async -> T) async -> T? {
        guard await acquire() else { return nil }
        let result = await body()
        await release()
        return result
    }
}
