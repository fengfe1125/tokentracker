//
//  UpdaterModel.swift
//  TokenTrackerApp
//
//  设置页「关于」的更新状态机：检查 → 下载 → 安装 → 重启。
//  所有耗时步骤都在后台，主线程只改状态。
//

import AppKit
import Foundation
import TokenTrackerCore

enum UpdateStage: Equatable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case downloading(Double)
    case installing
    case installed          // 换好了，等重启
    case failed(String)
}

@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var stage: UpdateStage = .idle

    private let installer = UpdateInstaller()

    /// 只有以 .app 方式运行才能自我更新（swift run 出来的裸二进制不行）
    var appPath: String? {
        let path = Bundle.main.bundleURL.path
        return path.hasSuffix(".app") ? path : nil
    }

    var busy: Bool {
        switch stage {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func check(applyTo state: AppState?) {
        guard !busy else { return }
        stage = .checking
        let installer = self.installer
        Task {
            let result: Result<(UpdateInfo?, ReleaseInfo), Error> = await Task.detached {
                do {
                    // force：手动检查要绕开 24h 缓存；顺带把共享缓存刷新掉
                    let cached = UpdateChecker().check(force: true)
                    return .success((cached, try installer.latestRelease()))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .failure(let error):
                stage = .failed(Self.describe(error))
            case .success(let (info, release)):
                if let info { state?.updateInfo = info }
                let newer = UpdateChecker.updateAvailable(
                    UpdateInfo(latest: release.tag, url: release.htmlURL, checkedAt: 0),
                    current: TokenTrackerCore.version)
                stage = newer ? .available(release) : .upToDate
            }
        }
    }

    func downloadAndInstall(_ release: ReleaseInfo) {
        guard !busy, let appPath, let asset = release.dmg else { return }
        stage = .downloading(0)
        let installer = self.installer
        Task {
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.stage { self?.stage = .downloading(value) }
                }
            }
            let downloaded: Result<URL, Error> = await Task.detached {
                do { return .success(try installer.downloadFile(asset.downloadURL, progress)) }
                catch { return .failure(error) }
            }.value
            guard case .success(let dmg) = downloaded else {
                if case .failure(let error) = downloaded { stage = .failed(Self.describe(error)) }
                return
            }
            stage = .installing
            let installed: Result<Void, Error> = await Task.detached {
                defer { try? FileManager.default.removeItem(at: dmg) }
                do {
                    try installer.install(dmg: dmg, into: appPath, expectedSHA256: asset.sha256)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            switch installed {
            case .success: stage = .installed
            case .failure(let error): stage = .failed(Self.describe(error))
            }
        }
    }

    /// 自身 bundle 已经被换掉，只能让外部进程等本进程退出后再把新版本拉起来。
    func relaunch() {
        guard let appPath else { return }
        installer.scheduleRelaunch(appPath: appPath)
        NSApp.terminate(nil)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
