import CWGPU
import XRender

#if canImport(Darwin)
import Darwin
#endif
#if canImport(os)
import os
#endif

/// Route a renderer diagnostic to wherever this platform can surface it:
/// `os_log` (visible via `log stream`/Console) on Apple, stderr elsewhere.
@inline(__always)
func rendererLog(_ message: String) {
    #if canImport(os)
    os_log("%{public}s", log: OSLog(subsystem: "XRender.WGPU", category: "wgpu"), type: .default, message)
    #elseif canImport(Darwin)
    fputs("\(message)\n", stderr)
    #else
    print(message)
    #endif
}

// wgpu-native(v29 系, WGPUStringView / *CallbackInfo スタイル)を Swift から
// 呼ぶための最小ヘルパ群。スパイク用。

// MARK: - 文字列

/// Swift String を、クロージャ実行中だけ有効な `WGPUStringView` として渡す。
/// wgpu-native は create 系呼び出し中に内容をコピーするので、この寿命で足りる。
@inline(__always)
func withWGPUString<R>(_ string: String, _ body: (WGPUStringView) -> R) -> R {
    var s = string
    return s.withUTF8 { buf in
        body(WGPUStringView(data: buf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                            length: buf.count))
    }
}

// MARK: - チェーン構造体

/// 値型のチェーン拡張構造体(先頭フィールドが `WGPUChainedStruct chain`)を
/// 親記述子の `nextInChain` に差し込んでクロージャを実行する。
@inline(__always)
func withChained<C, R>(_ chained: inout C, _ body: (UnsafeMutablePointer<WGPUChainedStruct>) -> R) -> R {
    withUnsafeMutablePointer(to: &chained) { ptr in
        body(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: WGPUChainedStruct.self))
    }
}

// MARK: - ログ

/// wgpu-native の内部ログ(バリデーションエラー含む)を stderr へ。once。
/// これが無いと `wgpuCommandEncoderFinish` が nil を返す理由が全く見えない。
func installWGPULoggingOnce() {
    struct Once { static let run: Void = {
        wgpuSetLogLevel(WGPULogLevel_Warn)
        wgpuSetLogCallback({ level, message, _ in
            let text: String
            if let data = message.data, message.length > 0 {
                text = String(decoding: UnsafeRawBufferPointer(start: data, count: message.length), as: UTF8.self)
            } else {
                text = "(no message)"
            }
            let tag: String
            switch level {
            case WGPULogLevel_Error: tag = "ERROR"
            case WGPULogLevel_Warn: tag = "WARN"
            case WGPULogLevel_Info: tag = "INFO"
            default: tag = "LOG"
            }
            rendererLog("[WGPU \(tag)] \(text)")
        }, nil)
    }() }
    _ = Once.run
}

private func reportUncapturedError(_ type: WGPUErrorType, _ message: WGPUStringView) {
    let text: String
    if let data = message.data, message.length > 0 {
        text = String(decoding: UnsafeRawBufferPointer(start: data, count: message.length), as: UTF8.self)
    } else {
        text = "(no message)"
    }
    rendererLog("[WGPU UNCAPTURED \(type.rawValue)] \(text)")
}

// MARK: - 非同期リクエストの同期化

private final class AdapterBox { var adapter: WGPUAdapter?; var done = false }
private final class DeviceBox { var device: WGPUDevice?; var done = false }

/// `wgpuInstanceRequestAdapter` を同期で待つ。wgpu-native はコールバックを
/// リクエスト呼び出し中に発火することが多いが、念のため process events を回す。
func requestAdapterSync(instance: WGPUInstance, surface: WGPUSurface?) -> WGPUAdapter? {
    let box = AdapterBox()
    var options = WGPURequestAdapterOptions()
    options.compatibleSurface = surface

    var info = WGPURequestAdapterCallbackInfo()
    info.mode = WGPUCallbackMode_AllowProcessEvents
    info.callback = { _, adapter, _, ud1, _ in
        let box = Unmanaged<AdapterBox>.fromOpaque(ud1!).takeUnretainedValue()
        box.adapter = adapter
        box.done = true
    }
    info.userdata1 = Unmanaged.passUnretained(box).toOpaque()

    _ = wgpuInstanceRequestAdapter(instance, &options, info)

    var spins = 0
    while !box.done && spins < 2048 {
        wgpuInstanceProcessEvents(instance)
        spins += 1
    }
    return box.adapter
}

/// `wgpuAdapterRequestDevice` を同期で待つ(既定デバイス)。
func requestDeviceSync(instance: WGPUInstance, adapter: WGPUAdapter) -> WGPUDevice? {
    let box = DeviceBox()

    var info = WGPURequestDeviceCallbackInfo()
    info.mode = WGPUCallbackMode_AllowProcessEvents
    info.callback = { _, device, _, ud1, _ in
        let box = Unmanaged<DeviceBox>.fromOpaque(ud1!).takeUnretainedValue()
        box.device = device
        box.done = true
    }
    info.userdata1 = Unmanaged.passUnretained(box).toOpaque()

    var descriptor = WGPUDeviceDescriptor()
    descriptor.uncapturedErrorCallbackInfo.callback = { _, type, message, _, _ in
        reportUncapturedError(type, message)
    }
    _ = wgpuAdapterRequestDevice(adapter, &descriptor, info)

    var spins = 0
    while !box.done && spins < 2048 {
        wgpuInstanceProcessEvents(instance)
        spins += 1
    }
    return box.device
}
