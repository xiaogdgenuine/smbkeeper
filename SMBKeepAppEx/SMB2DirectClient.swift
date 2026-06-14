/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
为 SMB 后端的 FSKit 卷提供的异步、非阻塞 libsmb2 客户端。

所有操作都跑在单一的串行事件循环队列（`loop`）上，由它独占持有 `smb2_context`。
我们使用 libsmb2 的 *异步* API（`smb2_*_async`）配合其事件系统原语
（`smb2_get_fd` / `smb2_which_events` / `smb2_service`），从而请求提交不阻塞，
回复由监视 socket 的 `DispatchSource` 派发。这消除了旧同步设计的队头阻塞
（旧设计中串行队列上一个卡住的调用会冻结整个挂载），且无需任何 `NSLock`：
所有可变状态都限定在 `loop` 上访问。

多个请求可以同时在途（SMB2 在同一条连接上对它们多路复用），因此一个慢的或卡住的
read 不再阻塞元数据操作。网络变化时我们直接销毁 context：`smb2_destroy_context`
会用 `SMB2_STATUS_SHUTDOWN` 调用每个在途请求的回调，于是在途操作立即失败，
而不是傻等超时。
*/

import Foundation
import SMB2
import OSLog
import Semaphore

/// 作为每个请求的 `cb_data` 交给 libsmb2 的令牌。C 完成回调会把它还原成 Swift 对象，
/// 并路由到所属的 client。
private final class SMB2RequestToken {
    let id: UInt64
    unowned let client: SMB2DirectClient
    init(id: UInt64, client: SMB2DirectClient) {
        self.id = id
        self.client = client
    }
}

/// 每个 `smb2_*_async` 调用的 C 完成回调。运行在 client 的 `loop` 上
/// （libsmb2 只在 `smb2_service` / `smb2_destroy_context` 中调用它，
/// 而这两者我们都只在 `loop` 上调用）。
private func smb2RequestCompletion(_ smb2: UnsafeMutablePointer<smb2_context>?,
                                   _ status: Int32,
                                   _ commandData: UnsafeMutableRawPointer?,
                                   _ cbData: UnsafeMutableRawPointer?) {
    guard let cbData else { return }
    let token = Unmanaged<SMB2RequestToken>.fromOpaque(cbData).takeRetainedValue()
    token.client.completeRequest(id: token.id, status: status, commandData: commandData)
}

/// 构建在 libsmb2 异步 API 之上的线程安全 SMB2 客户端。
final class SMB2DirectClient: @unchecked Sendable {

    // MARK: 存储状态（全部只在 `loop` 上访问）

    private var context: UnsafeMutablePointer<smb2_context>?
    private let loop = DispatchQueue(label: "com.apple.fskit.smbkeepfs.libsmb2.loop")
    private let config: SMBConfiguration
    private let logger: TimestampedLogger

    /// 在途请求，以单调递增的 id 为键。存储的闭包负责解释 libsmb2 的 status/command-data，
    /// 并且只 resume 等待中的 continuation 一次。
    private var nextID: UInt64 = 1
    private var pending: [UInt64: (Int32, UnsafeMutableRawPointer?) -> Void] = [:]

    /// 以 SMB 路径为键的已打开文件句柄，在多次 read/write 调用间复用。
    private struct CachedHandle {
        var fh: OpaquePointer
        var writable: Bool
    }
    private var handles: [String: CachedHandle] = [:]

    /// 按路径合并 open：对同一路径并发的 `acquireHandle` 调用共享同一次 `smb2_open`。
    private struct OpenWaiter {
        let needWrite: Bool
        let createIfMissing: Bool
        let continuation: CheckedContinuation<OpaquePointer, Error>
    }
    private var openWaiters: [String: [OpenWaiter]] = [:]
    private var opening: Set<String> = []

    // 在 `loop` 上驱动 smb2_service 的事件源。
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSuspended = true
    private var monitoredFD: Int32 = -1

    // 周期性 tick：让 libsmb2 过期掉超时的 PDU，并发送 keepalive echo。
    private var tickTimer: DispatchSourceTimer?
    private var ticksSinceEcho = 0
    private let echoEveryTicks = 30

    // 针对连接握手的一次性挂钟兜底（见 `armConnectDeadline`）。
    private var connectDeadlineTimer: DispatchSourceTimer?

    // 单飞（single-flight）重连：用信号量保证同一时刻只有一个重连在跑。
    private let reconnectSemaphore = AsyncSemaphore(value: 1)

    /// 固定的 libsmb2 单操作超时（秒）。局域网 SMB 很快，因此用一个短而统一的截止时间
    /// 来限制卡住的请求在被 libsmb2 中止前能拖多久；单次 SMB RPC 正常情况下绝不需要更久。
    private static let operationTimeout: Int32 = 10

    /// 连接握手的硬性挂钟上限（秒）。libsmb2 的单操作超时只有在 PDU 已入队、
    /// 且 `smb2_service` 被周期性调用时才会触发，所以面向黑洞/半开网络的纯 TCP-connect 阶段
    /// 本身没有任何上界。这个定时器是兜底，保证 `connect()` 尽快失败，
    /// 从而切换网络后不会因为一次卡住的重连拖太久。
    private static let connectDeadline: TimeInterval = 5

    init(config: SMBConfiguration) {
        self.config = config
        self.logger = TimestampedLogger(subsystem: "com.apple.fskit.SMBKeepFS", category: config.connectionID)
    }

    deinit {
        // 到 deinit 执行时，已没有外部引用，也没有 loop 上的 block/handler 持有 `self`
        //（事件源/定时器都用 `[weak self]`），因此该 context 的事件循环已空闲。
        // 直接销毁即可；这里若用 `loop.sync`，万一最后一次释放发生在 `loop` 上会死锁。
        teardownContext()
    }

    // MARK: - 连接生命周期

    /// 建立 SMB 连接。在事件循环上驱动 libsmb2 的异步 connect，
    /// 在共享连接成功（或失败）时完成。
    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loop.async {
                guard let ctx = smb2_init_context() else {
                    cont.resume(throwing: POSIXError(.ENOMEM))
                    return
                }
                self.logger.debug("libsmb2 connecting to \(self.config.serverURL)/\(self.config.shareName) as \(self.config.username)")
                smb2_set_timeout(ctx, Self.operationTimeout)
                smb2_set_security_mode(ctx, UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
                smb2_set_authentication(ctx, Int32(SMB2_SEC_NTLMSSP.rawValue))
                self.config.username.withCString { smb2_set_user(ctx, $0) }
                if self.config.password.isEmpty {
                    smb2_set_password(ctx, nil)
                } else {
                    self.config.password.withCString { smb2_set_password(ctx, $0) }
                }
                self.context = ctx

                let id = self.nextID
                self.nextID &+= 1
                let raw = Unmanaged.passRetained(SMB2RequestToken(id: id, client: self)).toOpaque()
                self.pending[id] = { status, _ in
                    self.cancelConnectDeadline()
                    if status < 0 {
                        let err = SMB2LibSupport.posixError(fromContext: self.context, code: status)
                        self.logger.error("libsmb2 connect failed: \(err)")
                        // 这个完成回调是在处理 connect 握手期间 *在 smb2_service 内部* 运行的，
                        // 所以不要在这里销毁 context（会 use-after-free）。把 teardown 延后执行。
                        self.loop.async { self.teardownContext() }
                        cont.resume(throwing: err)
                    } else {
                        self.logger.debug("libsmb2 connected to \(self.config.shareName)")
                        self.startTick()
                        cont.resume()
                    }
                }

                let server = SMB2LibSupport.serverAddress(from: self.config.serverURL)
                let rc = server.withCString { s in
                    self.config.shareName.withCString { sh in
                        self.config.username.withCString { u in
                            smb2_connect_share_async(ctx, s, sh, u, smb2RequestCompletion, raw)
                        }
                    }
                }
                if self.pending[id] != nil {
                    if rc < 0 {
                        self.pending.removeValue(forKey: id)
                        Unmanaged<SMB2RequestToken>.fromOpaque(raw).release()
                        let err = SMB2LibSupport.posixError(fromContext: ctx, code: rc)
                        self.logger.error("libsmb2 connect submit failed: \(err)")
                        self.teardownContext()
                        cont.resume(throwing: err)
                    } else {
                        self.updateEventSources()
                        // 在握手期间驱动 smb2_service（让 libsmb2 能过期 negotiate/session 的 PDU），
                        // 并为 PDU 出现之前的 TCP-connect 阶段装上挂钟兜底。
                        self.startTick()
                        self.armConnectDeadline(id: id)
                    }
                }
            }
        }
    }

    /// 拆除连接（优雅卸载/停用）。非阻塞。
    func disconnect() {
        loop.async {
            self.logger.debug("libsmb2 disconnecting from \(self.config.shareName)")
            self.teardownContext()
        }
    }

    /// 重连。用信号量保证同一时刻只有一个重连在跑；并发调用方排队等待。
    @discardableResult
    func reconnect() async -> Bool {
        // 记下进入等待前的 context。若在排队期间别人已经重连出新的 context，
        // 直接复用即可，不必把刚建好的连接又拆掉重连一遍。
        let previous = await awaitOnLoop { self.context }
        await reconnectSemaphore.wait()
        defer { reconnectSemaphore.signal() }

        let current = await awaitOnLoop { self.context }
        if let current, current != previous {
            return true
        }
        return await performReconnect()
    }

    private func performReconnect() async -> Bool {
        self.logger.debug("libsmb2 reconnecting to \(self.config.serverURL)/\(self.config.shareName)")
        // 先拆掉（假定已死的）context；这会通过 SMB2_STATUS_SHUTDOWN 立即让所有在途请求失败，
        // 而不是在一个已死的 socket 上傻等。
        await awaitOnLoop { self.teardownContext() }
        do {
            try await connect()
            self.logger.debug("libsmb2 reconnect succeeded")
            return true
        } catch {
            self.logger.error("libsmb2 reconnect failed: \(error)")
            return false
        }
    }

    func isConnectionLost(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ENOTCONN, .ETIMEDOUT, .ESTALE, .ECONNRESET, .ECONNABORTED,
                 .ENETDOWN, .ENETUNREACH, .ENETRESET, .EHOSTDOWN, .EHOSTUNREACH,
                 .EPIPE, .ESHUTDOWN, .EIO, .EBADF, .EINTR:
                return true
            default:
                break
            }
        }
        let message = (error as NSError).localizedDescription.lowercased()
        let markers = ["pollhup", "socket error", "connection reset", "connection refused",
                       "broken pipe", "timed out", "timeout", "not connected",
                       "disconnected", "connection closed", "session setup", "shutdown"]
        return markers.contains { message.contains($0) }
    }

    // MARK: - 事件循环管道（运行在 `loop` 上）

    private func updateEventSources() {
        guard let ctx = self.context else { disposeSources(); return }
        let fd = smb2_get_fd(ctx)
        guard fd >= 0 else { disposeSources(); return }
        if fd != monitoredFD { installSources(fd: fd) }
        let events = smb2_which_events(ctx)
        if (events & Int32(POLLOUT)) != 0 { enableWriteSource() } else { disableWriteSource() }
    }

    private func installSources(fd: Int32) {
        disposeSources()
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: loop)
        read.setEventHandler { [weak self] in self?.service(Int32(POLLIN)) }
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: loop)
        write.setEventHandler { [weak self] in self?.service(Int32(POLLOUT)) }
        self.readSource = read
        self.writeSource = write
        self.writeSuspended = true
        self.monitoredFD = fd
        read.resume()
    }

    private func enableWriteSource() {
        guard writeSuspended, let write = writeSource else { return }
        write.resume()
        writeSuspended = false
    }

    private func disableWriteSource() {
        guard !writeSuspended, let write = writeSource else { return }
        write.suspend()
        writeSuspended = true
    }

    private func disposeSources() {
        if let read = readSource {
            read.setEventHandler {}
            read.cancel()
            readSource = nil
        }
        if let write = writeSource {
            // 处于挂起状态的 source 必须先 resume 才能释放。
            if writeSuspended { write.resume(); writeSuspended = false }
            write.setEventHandler {}
            write.cancel()
            writeSource = nil
        }
        monitoredFD = -1
    }

    private func service(_ revents: Int32) {
        guard let ctx = self.context else { return }
        if smb2_service(ctx, revents) < 0 {
            self.logger.error("libsmb2 smb2_service failed; tearing down context")
            teardownContext()
            return
        }
        updateEventSources()
    }

    private func startTick() {
        stopTick()
        let timer = DispatchSource.makeTimerSource(queue: loop)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.tickTimer = timer
        self.ticksSinceEcho = 0
        timer.resume()
    }

    private func stopTick() {
        tickTimer?.cancel()
        tickTimer = nil
    }

    /// 装上一次性的连接兜底。如果 `id` 对应的 connect 在 `connectDeadline` 之前还没完成，
    /// 就销毁 context：这会触发那个在途的 connect 回调（带 SHUTDOWN/CANCELLED），
    /// 从而释放请求令牌，并以错误 resume 正在等待的 `connect()`。运行在 `loop` 上，
    /// 所以绝不会与同一队列上并发的 `smb2_service` 竞争。
    private func armConnectDeadline(id: UInt64) {
        cancelConnectDeadline()
        let timer = DispatchSource.makeTimerSource(queue: loop)
        timer.schedule(deadline: .now() + Self.connectDeadline)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.connectDeadlineTimer = nil
            // 如果 connect 已经完成，它的完成回调会移除 `pending[id]`。
            guard self.pending[id] != nil else { return }
            self.logger.error("libsmb2 connect timed out after \(Self.connectDeadline)s; tearing down context")
            self.teardownContext()
        }
        self.connectDeadlineTimer = timer
        timer.resume()
    }

    private func cancelConnectDeadline() {
        connectDeadlineTimer?.cancel()
        connectDeadlineTimer = nil
    }

    private func tick() {
        guard self.context != nil else { return }
        // 让 libsmb2 过期掉任何超时的 PDU（启用超时后，它要求至少每秒调用一次 smb2_service）。
        service(0)
        guard self.context != nil else { return }
        ticksSinceEcho += 1
        if ticksSinceEcho >= echoEveryTicks {
            ticksSinceEcho = 0
            sendKeepalive()
        }
    }

    private func sendKeepalive() {
        guard let ctx = self.context else { return }
        let id = self.nextID
        self.nextID &+= 1
        let raw = Unmanaged.passRetained(SMB2RequestToken(id: id, client: self)).toOpaque()
        // echo 仅用于保活；失败不在这里主动重连，留给下一次真实操作懒重连，
        // 避免“销毁旧 context → echo 失败 → 又重连”的循环。
        self.pending[id] = { [weak self] status, _ in
            if status < 0 { self?.logger.debug("libsmb2 keepalive echo failed (\(status))") }
        }
        let rc = smb2_echo_async(ctx, smb2RequestCompletion, raw)
        if self.pending[id] != nil {
            if rc < 0 {
                self.pending.removeValue(forKey: id)
                Unmanaged<SMB2RequestToken>.fromOpaque(raw).release()
            } else {
                updateEventSources()
            }
        }
    }

    /// 销毁 context 并让所有在途工作失败。运行在 `loop` 上。
    private func teardownContext() {
        stopTick()
        cancelConnectDeadline()
        disposeSources()
        if let ctx = self.context {
            // 不再只依赖 smb2_destroy_context 回调所有在途请求。实际网络切换时，
            // 如果某个请求没有被 libsmb2 回调，FSKit 的 replyHandler 就永远不执行，
            // Finder 会一直卡在 getattrlist / readdir。这里先主动失败所有 pending。
            let requests = self.pending
            self.pending.removeAll(keepingCapacity: true)
            for (_, completion) in requests {
                completion(-Int32(ENOTCONN), nil)
            }
            self.context = nil
            smb2_destroy_context(ctx)
        }
        // 这些 fh 结构由（现已销毁的）context 拥有；直接丢弃引用即可。
        handles.removeAll()
        if !openWaiters.isEmpty {
            let err = POSIXError(.ENOTCONN)
            for (_, waiters) in openWaiters {
                for w in waiters { w.continuation.resume(throwing: err) }
            }
            openWaiters.removeAll()
        }
        opening.removeAll()
    }

    // MARK: - 请求完成汇集点（运行在 `loop` 上）

    fileprivate func completeRequest(id: UInt64, status: Int32, commandData: UnsafeMutableRawPointer?) {
        guard let completion = pending.removeValue(forKey: id) else { return }
        completion(status, commandData)
    }

    // MARK: - 通用 submit

    /// 提交一次异步 libsmb2 调用并 await 其完成。
    /// - `prepare`：发起 `smb2_*_async` 调用；返回其提交时的 rc。
    /// - `interpret`：把完成结果（status + command-data）映射为一个 result。
    /// - `cleanup`：总是恰好运行一次（释放任何堆缓冲区）。
    private func submit<T>(
        prepare: @escaping (UnsafeMutablePointer<smb2_context>, UnsafeMutableRawPointer) -> Int32,
        interpret: @escaping (Int32, UnsafeMutableRawPointer?, UnsafeMutablePointer<smb2_context>) -> Result<T, Error>,
        cleanup: (() -> Void)? = nil
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            loop.async {
                guard let ctx = self.context else {
                    cleanup?()
                    cont.resume(throwing: POSIXError(.ENOTCONN))
                    return
                }
                let id = self.nextID
                self.nextID &+= 1
                let raw = Unmanaged.passRetained(SMB2RequestToken(id: id, client: self)).toOpaque()
                self.pending[id] = { status, commandData in
                    let result = interpret(status, commandData, ctx)
                    cleanup?()
                    cont.resume(with: result)
                }
                let rc = prepare(ctx, raw)
                // 如果回调已经同步触发（libsmb2 某些错误路径会这样），
                // 那么 `pending[id]` 已被移除，一切都已处理完毕。
                if self.pending[id] != nil {
                    if rc < 0 {
                        self.pending.removeValue(forKey: id)
                        Unmanaged<SMB2RequestToken>.fromOpaque(raw).release()
                        cleanup?()
                        cont.resume(throwing: SMB2LibSupport.posixError(fromContext: ctx, code: rc))
                    } else {
                        self.updateEventSources()
                    }
                }
            }
        }
    }

    private func submitVoid(
        _ prepare: @escaping (UnsafeMutablePointer<smb2_context>, UnsafeMutableRawPointer) -> Int32
    ) async throws {
        try await submit(prepare: prepare) { status, _, ctx in
            status < 0 ? .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status)) : .success(())
        }
    }

    // MARK: - 句柄缓存（在 `loop` 上合并 open）

    private func acquireHandle(path: String, needWrite: Bool, createIfMissing: Bool) async throws -> OpaquePointer {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OpaquePointer, Error>) in
            loop.async {
                guard self.context != nil else {
                    cont.resume(throwing: POSIXError(.ENOTCONN))
                    return
                }
                if let cached = self.handles[path], !needWrite || cached.writable {
                    cont.resume(returning: cached.fh)
                    return
                }
                self.openWaiters[path, default: []].append(
                    OpenWaiter(needWrite: needWrite, createIfMissing: createIfMissing, continuation: cont))
                if !self.opening.contains(path) {
                    self.opening.insert(path)
                    self.beginOpen(path: path)
                }
            }
        }
    }

    /// 为 `path` 启动一轮 `smb2_open`。必须在 `loop` 上运行。
    private func beginOpen(path: String) {
        guard let ctx = self.context else {
            failOpenWaiters(path: path, error: POSIXError(.ENOTCONN))
            return
        }
        let waiters = openWaiters[path] ?? []
        let wantWrite = waiters.contains { $0.needWrite }
        let createIfMissing = wantWrite && waiters.contains { $0.needWrite && $0.createIfMissing }
        var flags = wantWrite ? O_RDWR : O_RDONLY
        if createIfMissing { flags |= O_CREAT }

        let id = self.nextID
        self.nextID &+= 1
        let raw = Unmanaged.passRetained(SMB2RequestToken(id: id, client: self)).toOpaque()
        self.pending[id] = { status, commandData in
            self.finishOpen(path: path, openedWritable: wantWrite, status: status, commandData: commandData)
        }
        let rc = path.withCString { smb2_open_async(ctx, $0, flags, smb2RequestCompletion, raw) }
        if self.pending[id] != nil {
            if rc < 0 {
                self.pending.removeValue(forKey: id)
                Unmanaged<SMB2RequestToken>.fromOpaque(raw).release()
                finishOpen(path: path, openedWritable: wantWrite,
                           status: rc, commandData: nil)
            } else {
                updateEventSources()
            }
        }
    }

    /// 完成一轮 open，resume 已满足的 waiter；若有迟到的写入方需要升级权限，则再启动一轮。
    /// 必须在 `loop` 上运行。
    private func finishOpen(path: String, openedWritable: Bool, status: Int32,
                            commandData: UnsafeMutableRawPointer?) {
        self.opening.remove(path)
        let waiters = self.openWaiters.removeValue(forKey: path) ?? []

        if status < 0 {
            let err = SMB2LibSupport.posixError(fromContext: self.context, code: status)
            for w in waiters { w.continuation.resume(throwing: err) }
            return
        }
        guard let commandData else {
            let err = POSIXError(.EIO)
            for w in waiters { w.continuation.resume(throwing: err) }
            return
        }
        let fh = OpaquePointer(commandData)

        // 替换该路径之前缓存的任何句柄（比如只读的）。
        if let old = self.handles[path], old.fh != fh, let ctx = self.context {
            fireAndForgetClose(ctx: ctx, fh: old.fh)
        }
        self.handles[path] = CachedHandle(fh: fh, writable: openedWritable)

        var needAnotherRound: [OpenWaiter] = []
        for w in waiters {
            if !w.needWrite || openedWritable {
                w.continuation.resume(returning: fh)
            } else {
                needAnotherRound.append(w)
            }
        }
        if !needAnotherRound.isEmpty {
            self.openWaiters[path] = needAnotherRound
            self.opening.insert(path)
            beginOpen(path: path)
        }
    }

    private func failOpenWaiters(path: String, error: Error) {
        let waiters = self.openWaiters.removeValue(forKey: path) ?? []
        self.opening.remove(path)
        for w in waiters { w.continuation.resume(throwing: error) }
    }

    private func fireAndForgetClose(ctx: UnsafeMutablePointer<smb2_context>, fh: OpaquePointer) {
        let id = self.nextID
        self.nextID &+= 1
        let raw = Unmanaged.passRetained(SMB2RequestToken(id: id, client: self)).toOpaque()
        self.pending[id] = { _, _ in }
        let rc = smb2_close_async(ctx, fh, smb2RequestCompletion, raw)
        if self.pending[id] != nil {
            if rc < 0 {
                self.pending.removeValue(forKey: id)
                Unmanaged<SMB2RequestToken>.fromOpaque(raw).release()
            } else {
                updateEventSources()
            }
        }
    }

    /// 丢弃（并关闭）`path` 的缓存句柄（如果有）。运行在 `loop` 上。
    private func dropHandleOnLoop(_ path: String) {
        guard let cached = self.handles.removeValue(forKey: path) else { return }
        if let ctx = self.context { fireAndForgetClose(ctx: ctx, fh: cached.fh) }
    }

    /// 对外的关闭接口（文件 close / reclaim）。尽力而为，非阻塞。
    func closeHandle(forPath path: String) {
        let trimmed = path.smbTrimmedPath
        loop.async { self.dropHandleOnLoop(trimmed) }
    }

    private func awaitOnLoop<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            loop.async { c.resume(returning: body()) }
        }
    }

    // MARK: - 元数据

    func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: any Sendable] {
        let trimmed = path.smbTrimmedPath
        do {
            let st = try await stat(path: trimmed)
            let name = (path as NSString).lastPathComponent
            return st.resourceDictionary(path: parentPath(of: trimmed), name: name.isEmpty ? trimmed : name)
        } catch let error as POSIXError where error.code == .ENOLINK {
            return try await statViaSymlinkOpen(path: trimmed)
        }
    }

    private func stat(path: String) async throws -> smb2_stat_64 {
        let stPtr = UnsafeMutablePointer<smb2_stat_64>.allocate(capacity: 1)
        stPtr.initialize(to: smb2_stat_64())
        return try await submit(
            prepare: { ctx, raw in path.withCString { smb2_stat_async(ctx, $0, stPtr, smb2RequestCompletion, raw) } },
            interpret: { status, _, ctx in
                status < 0
                    ? .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status))
                    : .success(stPtr.pointee)
            },
            cleanup: { stPtr.deinitialize(count: 1); stPtr.deallocate() }
        )
    }

    private func statViaSymlinkOpen(path: String) async throws -> [URLResourceKey: any Sendable] {
        let fh = try await openUncached(path: path, flags: O_RDONLY)
        defer { closeUncached(fh) }
        let st = try await fstat(fh: fh)
        let name = (path as NSString).lastPathComponent
        return st.resourceDictionary(path: parentPath(of: path), name: name.isEmpty ? path : name)
    }

    private func fstat(fh: OpaquePointer) async throws -> smb2_stat_64 {
        let stPtr = UnsafeMutablePointer<smb2_stat_64>.allocate(capacity: 1)
        stPtr.initialize(to: smb2_stat_64())
        return try await submit(
            prepare: { ctx, raw in smb2_fstat_async(ctx, fh, stPtr, smb2RequestCompletion, raw) },
            interpret: { status, _, ctx in
                status < 0
                    ? .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status))
                    : .success(stPtr.pointee)
            },
            cleanup: { stPtr.deinitialize(count: 1); stPtr.deallocate() }
        )
    }

    func attributesOfFileSystem(forPath path: String = "") async throws -> [FileAttributeKey: any Sendable] {
        let trimmed = path.smbTrimmedPath
        let vfsPtr = UnsafeMutablePointer<smb2_statvfs>.allocate(capacity: 1)
        vfsPtr.initialize(to: smb2_statvfs())
        return try await submit(
            prepare: { ctx, raw in trimmed.withCString { smb2_statvfs_async(ctx, $0, vfsPtr, smb2RequestCompletion, raw) } },
            interpret: { status, _, ctx in
                if status < 0 {
                    return .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status))
                }
                let st = vfsPtr.pointee
                var attrs = [FileAttributeKey: any Sendable]()
                let blockSize = UInt64(st.f_bsize)
                attrs[.systemSize] = NSNumber(value: blockSize * UInt64(st.f_blocks))
                attrs[.systemFreeSize] = NSNumber(value: blockSize * UInt64(st.f_bavail))
                attrs[.systemNodes] = NSNumber(value: st.f_files)
                attrs[.systemFreeNodes] = NSNumber(value: st.f_ffree)
                return .success(attrs)
            },
            cleanup: { vfsPtr.deinitialize(count: 1); vfsPtr.deallocate() }
        )
    }

    func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: any Sendable]] {
        let trimmed = path.smbTrimmedPath
        return try await submit(
            prepare: { ctx, raw in trimmed.withCString { smb2_opendir_async(ctx, $0, smb2RequestCompletion, raw) } },
            interpret: { status, commandData, ctx in
                if status < 0 {
                    return .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status))
                }
                guard let commandData else { return .failure(POSIXError(.EIO)) }
                let dir = commandData.assumingMemoryBound(to: smb2dir.self)
                defer { smb2_closedir(ctx, dir) }
                var entries = [[URLResourceKey: any Sendable]]()
                while let ent = smb2_readdir(ctx, dir) {
                    let name = String(cString: ent.pointee.name)
                    if name == "." || name == ".." { continue }
                    let st = ent.pointee.st
                    entries.append(st.resourceDictionary(path: trimmed, name: name))
                }
                return .success(entries)
            }
        )
    }

    // MARK: - 写操作

    func setAttributes(_ attributes: [URLResourceKey: Any], atPath path: String) async throws {
        // 通过 SMB2 set-info 修改日期/标志位可后续再加；size 由 `truncateFile` 处理。
        _ = attributes
        _ = path
    }

    func truncateFile(atPath path: String, atOffset: UInt64) async throws {
        let trimmed = path.smbTrimmedPath
        await awaitOnLoop { self.dropHandleOnLoop(trimmed) }
        try await submitVoid { ctx, raw in
            trimmed.withCString { smb2_truncate_async(ctx, $0, atOffset, smb2RequestCompletion, raw) }
        }
    }

    func createDirectory(atPath path: String) async throws {
        let trimmed = path.smbTrimmedPath
        try await submitVoid { ctx, raw in
            trimmed.withCString { smb2_mkdir_async(ctx, $0, smb2RequestCompletion, raw) }
        }
    }

    func createEmptyFile(atPath path: String) async throws {
        let trimmed = path.smbTrimmedPath
        let fh = try await openUncached(path: trimmed, flags: O_CREAT | O_EXCL | O_RDWR)
        closeUncached(fh)
    }

    func removeItem(atPath path: String) async throws {
        let trimmed = path.smbTrimmedPath
        await awaitOnLoop { self.dropHandleOnLoop(trimmed) }
        let st = try await stat(path: trimmed)
        if st.isDirectory {
            try await submitVoid { ctx, raw in
                trimmed.withCString { smb2_rmdir_async(ctx, $0, smb2RequestCompletion, raw) }
            }
        } else {
            try await submitVoid { ctx, raw in
                trimmed.withCString { smb2_unlink_async(ctx, $0, smb2RequestCompletion, raw) }
            }
        }
    }

    func moveItem(atPath path: String, toPath: String) async throws {
        let from = path.smbTrimmedPath
        let to = toPath.smbTrimmedPath
        await awaitOnLoop {
            self.dropHandleOnLoop(from)
            self.dropHandleOnLoop(to)
        }
        try await submitVoid { ctx, raw in
            from.withCString { fromPtr in
                to.withCString { toPtr in
                    smb2_rename_async(ctx, fromPtr, toPtr, smb2RequestCompletion, raw)
                }
            }
        }
    }

    func destinationOfSymbolicLink(atPath path: String) async throws -> String {
        let trimmed = path.smbTrimmedPath
        return try await submit(
            prepare: { ctx, raw in trimmed.withCString { smb2_readlink_async(ctx, $0, smb2RequestCompletion, raw) } },
            interpret: { status, commandData, ctx in
                if status < 0 {
                    return .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status))
                }
                guard let commandData else { return .failure(POSIXError(.EIO)) }
                return .success(String(cString: commandData.assumingMemoryBound(to: CChar.self)))
            }
        )
    }

    func createSymbolicLink(atPath path: String, withDestinationPath destination: String) async throws {
        throw POSIXError(.ENOTSUP)
    }

    // MARK: - I/O 读写

    func read(path: String, offset: UInt64, length: Int) async throws -> Data {
        let trimmed = path.smbTrimmedPath
        let fh = try await acquireHandle(path: trimmed, needWrite: false, createIfMissing: false)
        guard length > 0 else { return Data() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        return try await submit(
            prepare: { ctx, raw in smb2_pread_async(ctx, fh, buffer, UInt32(length), offset, smb2RequestCompletion, raw) },
            interpret: { status, _, ctx in
                if status < 0 {
                    return .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status))
                }
                return .success(Data(bytes: buffer, count: Int(status)))
            },
            cleanup: { buffer.deallocate() }
        )
    }

    func write(path: String, data: Data, offset: UInt64) async throws -> Int {
        let trimmed = path.smbTrimmedPath
        let fh = try await acquireHandle(path: trimmed, needWrite: true, createIfMissing: offset == 0)
        let count = data.count
        // libsmb2 在写完成前会以零拷贝方式持有该缓冲区的引用，
        // 因此用一份稳定的堆拷贝，而不是 Data.withUnsafeBytes。
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(count, 1))
        data.copyBytes(to: buffer, count: count)
        return try await submit(
            prepare: { ctx, raw in smb2_pwrite_async(ctx, fh, buffer, UInt32(count), offset, smb2RequestCompletion, raw) },
            interpret: { status, _, ctx in
                status < 0
                    ? .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status))
                    : .success(Int(status))
            },
            cleanup: { buffer.deallocate() }
        )
    }

    /// 把所有可写的缓存句柄刷写到服务器（对应 FSKit 的 `synchronize`）。
    func flushAll() async throws {
        let fhs: [OpaquePointer] = await awaitOnLoop {
            self.handles.values.filter { $0.writable }.map { $0.fh }
        }
        for fh in fhs {
            try await submitVoid { ctx, raw in smb2_fsync_async(ctx, fh, smb2RequestCompletion, raw) }
        }
    }

    // MARK: - 非缓存的 open/close 辅助方法

    private func openUncached(path: String, flags: Int32) async throws -> OpaquePointer {
        try await submit(
            prepare: { ctx, raw in path.withCString { smb2_open_async(ctx, $0, flags, smb2RequestCompletion, raw) } },
            interpret: { status, commandData, ctx in
                if status < 0 {
                    return .failure(SMB2LibSupport.posixError(fromContext: ctx, code: status))
                }
                guard let commandData else { return .failure(POSIXError(.EIO)) }
                return .success(OpaquePointer(commandData))
            }
        )
    }

    private func closeUncached(_ fh: OpaquePointer) {
        loop.async {
            guard let ctx = self.context else { return }
            self.fireAndForgetClose(ctx: ctx, fh: fh)
        }
    }

    // MARK: - 私有

    private func parentPath(of path: String) -> String {
        let trimmed = path.smbTrimmedPath
        guard let slash = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else {
            return ""
        }
        return String(trimmed[..<slash])
    }
}
