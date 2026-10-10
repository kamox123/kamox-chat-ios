
// MARK: - Школьный чат без интернета (то же, что LocalChatServer.java / LocalChatProxy.java в Android-версии)
// Этот файл при сборке дописывается в AppDelegate.swift (см. .github/workflows/ios.yml), импорты — в native/imports.swift.

/// Сервер школьного чата на iPhone: раздаёт страницу чата по Wi-Fi и пересылает сообщения всем подключённым.
/// Протокол тот же, что у Android: JSON-строки, сервер заворачивает их в {"seq":N,"ts":T,"c":id,"m":...}.
/// {"t":"~...} — мгновенное (рация, рисуемая линия), {"t":"hw...} — домашка, {"t":"draw...} — рисунок, {"t":"g...} — игры.
final class KamoxChatServer {
    static var shared: KamoxChatServer?
    static let maxMsg = 3 * 1024 * 1024

    let queue = DispatchQueue(label: "kamox.localchat")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var clients: [Int: KamoxConn] = [:]
    private var nextId = 1
    private var seq: Int64 = 0
    let assets: (String) -> Data?
    private let chat: KamoxChannel, hw: KamoxChannel, games: KamoxChannel, draw: KamoxChannel

    init(assets: @escaping (String) -> Data?, dir: URL?) {
        self.assets = assets
        chat = KamoxChannel(name: "chat", max: 500, maxBytes: 60_000_000, dir: dir)
        hw = KamoxChannel(name: "homework", max: 400, maxBytes: 2_000_000, dir: dir)
        games = KamoxChannel(name: "games", max: 2000, maxBytes: 2_000_000, dir: nil)
        draw = KamoxChannel(name: "draw", max: 6000, maxBytes: 12_000_000, dir: nil)
        for ch in [chat, hw] { for w in ch.items { seq = max(seq, KamoxChatServer.seqOf(w)) } }
    }

    static func start(assets: @escaping (String) -> Data?, dir: URL?) throws -> KamoxChatServer {
        if let s = shared, s.listener != nil { return s }
        let s = KamoxChatServer(assets: assets, dir: dir)
        try s.open()
        shared = s
        return s
    }

    static func stopAll() { shared?.close(); shared = nil }

    var clientCount: Int { return queue.sync { clients.count } }

    private func open() throws {
        var lastError: Error = NSError(domain: "kamox", code: 1, userInfo: [NSLocalizedDescriptionKey: "порт занят"])
        for p in [8080, 8090, 8181] {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(p)) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l: NWListener
            do { l = try NWListener(using: params, on: nwPort) } catch { lastError = error; continue }
            let sem = DispatchSemaphore(value: 0)
            var ready = false
            l.stateUpdateHandler = { st in
                switch st {
                case .ready: ready = true; sem.signal()
                case .failed(let e): lastError = e; sem.signal()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            if sem.wait(timeout: .now() + 3) == .timedOut || !ready { l.cancel(); continue }
            listener = l
            port = UInt16(p)
            return
        }
        throw lastError
    }

    private func close() {
        queue.sync {
            listener?.cancel(); listener = nil
            for c in clients.values { c.close() }
            clients.removeAll()
        }
    }

    private func accept(_ c: NWConnection) {
        let conn = KamoxConn(c, queue: queue)
        conn.onHead = { [weak self, weak conn] head in guard let self = self, let conn = conn else { return }; self.handleHead(conn, head) }
        conn.onText = { [weak self, weak conn] text in guard let self = self, let conn = conn else { return }; self.onMessage(conn, text) }
        conn.onClose = { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            if self.clients.removeValue(forKey: conn.id) != nil, conn.hello != nil { self.broadcast("{\"t\":\"leave\",\"c\":\(conn.id)}", except: nil) }
        }
        conn.start()
    }

    // HTTP: страница чата, проверка /ping, переход на WebSocket
    private func handleHead(_ conn: KamoxConn, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        var path = parts.count > 1 ? String(parts[1]) : "/"
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            if let k = line.firstIndex(of: ":") {
                h[line[..<k].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: k)...].trimmingCharacters(in: .whitespaces)
            }
        }
        if h["upgrade"]?.lowercased() == "websocket", let key = h["sec-websocket-key"] {
            conn.upgrade(key: key)
            conn.id = nextId; nextId += 1
            for ch in [chat, hw, games, draw] { for m in ch.items { conn.sendText(m) } }
            for o in clients.values where o.hello != nil { conn.sendText("{\"t\":\"join\",\"c\":\(o.id),\"m\":\(o.hello!)}") }
            conn.sendText("{\"t\":\"you\",\"c\":\(conn.id)}")
            clients[conn.id] = conn
            return
        }
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if path == "/ping" { conn.respond(200, "text/plain; charset=utf-8", Data("kamox".utf8)) }
        else if path == "/" || path == "/index.html", let page = assets("local.html") { conn.respond(200, "text/html; charset=utf-8", page) }
        else { conn.respond(404, "text/plain; charset=utf-8", Data("not found".utf8)) }
    }

    private func onMessage(_ c: KamoxConn, _ text: String) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("{"), raw.hasSuffix("}") else { return }
        if raw.hasPrefix("{\"t\":\"hello\"") {
            if raw.count > 2000 { return }
            c.hello = raw
            broadcast("{\"t\":\"join\",\"c\":\(c.id),\"m\":\(raw)}", except: nil)
            return
        }
        if raw.hasPrefix("{\"t\":\"typing\"") { broadcast("{\"t\":\"typing\",\"c\":\(c.id)}", except: c); return }
        // мгновенное: звук рации, рисуемая сейчас линия — только остальным, без сохранения
        if raw.hasPrefix("{\"t\":\"~") { broadcast("{\"c\":\(c.id),\"m\":\(raw)}", except: c); return }
        seq += 1
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let wrapped = "{\"seq\":\(seq),\"ts\":\(ts),\"c\":\(c.id),\"m\":\(raw)}"
        if raw.hasPrefix("{\"t\":\"drawclear\"") { draw.clear() }
        else if raw.hasPrefix("{\"t\":\"draw") { draw.add(wrapped) }
        else if raw.hasPrefix("{\"t\":\"hw") { hw.add(wrapped) }
        else if raw.hasPrefix("{\"t\":\"g") { games.add(wrapped) }
        else { chat.add(wrapped) }
        broadcast(wrapped, except: nil)
    }

    private func broadcast(_ text: String, except: KamoxConn?) {
        for o in clients.values where o !== except { o.sendText(text) }
    }

    static func seqOf(_ w: String) -> Int64 {
        guard let colon = w.firstIndex(of: ":"), let comma = w[colon...].firstIndex(of: ",") else { return 0 }
        return Int64(w[w.index(after: colon)..<comma]) ?? 0
    }

    /// Адреса iPhone в локальных сетях: сначала точка доступа (bridge100), потом Wi-Fi (en0). Мобильный интернет (pdp_ip) не берём.
    static func localAddresses() -> [String] {
        var found: [(Int, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            p = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("pdp_ip") || name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                let priv = ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")
                if priv { found.append((name.hasPrefix("bridge") ? 0 : name == "en0" ? 1 : 2, ip)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}

/// Хранилище одного вида сообщений: последние N в памяти, по желанию — копия в файле (дописывается построчно).
final class KamoxChannel {
    private(set) var items: [String] = []
    private let max: Int, maxBytes: Int, file: URL?
    private var bytes = 0, appended = 0

    init(name: String, max: Int, maxBytes: Int, dir: URL?) {
        self.max = max; self.maxBytes = maxBytes
        file = dir?.appendingPathComponent("kamox-local-\(name).txt")
        if let f = file, let text = try? String(contentsOf: f, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("{") { push(String(line)) }
        }
    }
    private func push(_ w: String) {
        items.append(w); bytes += w.utf8.count
        while items.count > max || bytes > maxBytes { bytes -= items.removeFirst().utf8.count }
    }
    func add(_ w: String) {
        push(w)
        guard let f = file else { return }
        appended += 1
        if appended > max { rewrite(); return }
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data((w + "\n").utf8)); h.closeFile() }
        else { try? Data((w + "\n").utf8).write(to: f) }
    }
    func clear() { items.removeAll(); bytes = 0; if file != nil { rewrite() } }
    private func rewrite() {
        appended = 0
        guard let f = file else { return }
        try? Data(items.map { $0 + "\n" }.joined().utf8).write(to: f)
    }
}

/// Одно подключение: сначала HTTP-заголовок, потом (если попросили) WebSocket.
final class KamoxConn {
    let c: NWConnection
    let queue: DispatchQueue
    var id = 0
    var hello: String?
    var onHead: ((String) -> Void)?
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private var buf: [UInt8] = []
    private var fragment: [UInt8] = []
    private var ws = false
    private var closed = false
    private var pending = 0

    init(_ c: NWConnection, queue: DispatchQueue) { self.c = c; self.queue = queue }

    func start() { c.start(queue: queue); receive() }

    private func receive() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let d = data, !d.isEmpty { self.buf.append(contentsOf: d); self.process() }
            if done || err != nil { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    private func process() {
        if !ws {
            guard let end = KamoxConn.headEnd(buf) else { if buf.count > 16384 { close() }; return }
            let head = String(decoding: buf[0..<end], as: UTF8.self)
            buf.removeFirst(end + 4)
            onHead?(head)
            if !ws { return }
        }
        parseFrames()
    }

    static func headEnd(_ b: [UInt8]) -> Int? {
        if b.count < 4 { return nil }
        for i in 0...(b.count - 4) where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 { return i }
        return nil
    }

    private func parseFrames() {
        while !closed {
            if buf.count < 2 { return }
            let b0 = buf[0], b1 = buf[1]
            let fin = b0 & 0x80 != 0, op = b0 & 0x0f, masked = b1 & 0x80 != 0
            var len = Int(b1 & 0x7f), off = 2
            if len == 126 { if buf.count < 4 { return }; len = Int(buf[2]) << 8 | Int(buf[3]); off = 4 }
            else if len == 127 { if buf.count < 10 { return }; len = 0; for i in 2..<10 { len = len << 8 | Int(buf[i]) }; off = 10 }
            if len > KamoxChatServer.maxMsg { close(); return }
            let need = off + (masked ? 4 : 0) + len
            if buf.count < need { return }
            var payload = Array(buf[(need - len)..<need])
            if masked { let m = Array(buf[off..<(off + 4)]); for i in 0..<payload.count { payload[i] ^= m[i & 3] } }
            buf.removeFirst(need)
            switch op {
            case 8: close(); return
            case 9: sendFrame(10, payload)
            case 0, 1, 2:
                fragment.append(contentsOf: payload)
                if fragment.count > KamoxChatServer.maxMsg { close(); return }
                if fin { let s = String(decoding: fragment, as: UTF8.self); fragment.removeAll(); onText?(s) }
            default: break
            }
        }
    }

    func upgrade(key: String) {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        ws = true
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
    }

    func respond(_ code: Int, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Not Found")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        c.send(content: out, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func sendText(_ text: String) { sendFrame(1, Array(text.utf8)) }

    func sendFrame(_ op: UInt8, _ p: [UInt8]) {
        if closed { return }
        if pending > 80 * 1024 * 1024 { close(); return } // совсем не принимает — отключаем
        var f: [UInt8] = [0x80 | op]
        let len = p.count
        if len < 126 { f.append(UInt8(len)) }
        else if len < 65536 { f.append(126); f.append(UInt8(len >> 8 & 0xff)); f.append(UInt8(len & 0xff)) }
        else { f.append(127); for i in (0..<8).reversed() { f.append(UInt8((len >> (8 * i)) & 0xff)) } }
        f.append(contentsOf: p)
        let n = f.count
        pending += n
        c.send(content: Data(f), completion: .contentProcessed { [weak self] _ in self?.pending -= n })
    }

    func close() {
        if closed { return }
        closed = true
        c.cancel()
        onClose?()
    }
}

/// Переходник для гостя: страница чата открывается с 127.0.0.1 (там iPhone даёт микрофон для рации),
/// а WebSocket пересылается на телефон-сервер байт в байт. Слушает только сам iPhone.
final class KamoxProxy {
    static var shared: KamoxProxy?
    let queue = DispatchQueue(label: "kamox.proxy")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var target: (String, UInt16) = ("", 8080)
    let assets: (String) -> Data?

    init(assets: @escaping (String) -> Data?) { self.assets = assets }

    static func start(assets: @escaping (String) -> Data?, host: String, port: UInt16) throws -> UInt16 {
        let p = shared ?? KamoxProxy(assets: assets)
        p.target = (host, port)
        if p.listener == nil { try p.open() }
        shared = p
        return p.port
    }

    private func open() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        let sem = DispatchSemaphore(value: 0)
        var ready = false
        l.stateUpdateHandler = { st in
            switch st { case .ready: ready = true; sem.signal(); case .failed: sem.signal(); default: break }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 3)
        guard ready, let p = l.port else { l.cancel(); throw NSError(domain: "kamox", code: 2, userInfo: [NSLocalizedDescriptionKey: "переходник не запустился"]) }
        listener = l
        port = p.rawValue
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        var buf: [UInt8] = []
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self = self else { return }
                if let d = data { buf.append(contentsOf: d) }
                if let end = KamoxConn.headEnd(buf) {
                    let head = String(decoding: buf[0..<end], as: UTF8.self)
                    if head.lowercased().contains("upgrade: websocket") { self.pipe(c, first: buf) }
                    else {
                        let page = self.assets("local.html") ?? Data()
                        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                        out.append(page)
                        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
                    }
                    return
                }
                if done || err != nil || buf.count > 16384 { c.cancel(); return }
                read()
            }
        }
        read()
    }

    // WebSocket гостя: соединяемся с телефоном-сервером и перекачиваем байты в обе стороны
    private func pipe(_ c: NWConnection, first: [UInt8]) {
        guard let port = NWEndpoint.Port(rawValue: target.1) else { c.cancel(); return }
        let up = NWConnection(host: NWEndpoint.Host(target.0), port: port, using: .tcp)
        up.start(queue: queue)
        up.send(content: Data(first), completion: .contentProcessed { _ in })
        func pump(_ from: NWConnection, _ to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                if let d = data, !d.isEmpty { to.send(content: d, completion: .contentProcessed { _ in }) }
                if done || err != nil { from.cancel(); to.cancel(); return }
                pump(from, to)
            }
        }
        pump(c, up)
        pump(up, c)
    }
}

/// Поиск школьного чата в той же сети. Apple не даёт бесплатным приложениям широковещательные запросы,
/// поэтому по очереди спрашиваем /ping у адресов своей подсети (сначала .1 — обычно это точка доступа).
enum KamoxFinder {
    static func find(_ done: @escaping (String?) -> Void) {
        var candidates: [String] = []
        for ip in KamoxChatServer.localAddresses() {
            let parts = ip.split(separator: ".")
            if parts.count != 4 { continue }
            let base = parts[0...2].joined(separator: ".")
            candidates.append(base + ".1")
            for i in 2...254 where "\(base).\(i)" != ip { candidates.append("\(base).\(i)") }
        }
        if candidates.isEmpty { done(nil); return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.9
        cfg.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: cfg)
        let lock = NSLock()
        var found: String?
        var idx = 0
        var finished = false
        let group = DispatchGroup()
        func next() {
            lock.lock()
            if found != nil || idx >= candidates.count { lock.unlock(); return }
            let ip = candidates[idx]; idx += 1
            lock.unlock()
            for port in [8080, 8090, 8181] {
                guard let url = URL(string: "http://\(ip):\(port)/ping") else { continue }
                group.enter()
                session.dataTask(with: url) { data, resp, _ in
                    if let d = data, (resp as? HTTPURLResponse)?.statusCode == 200, String(decoding: d, as: UTF8.self) == "kamox" {
                        lock.lock(); if found == nil { found = "http://\(ip):\(port)/" }; lock.unlock()
                    }
                    if port == 8080 { next() }
                    group.leave()
                }.resume()
            }
        }
        for _ in 0..<24 { next() }
        group.notify(queue: .main) {
            if finished { return }
            finished = true
            session.invalidateAndCancel()
            done(found)
        }
    }
}

/// Мостик для страниц приложения: window.webkit.messageHandlers.kamoxLocal.postMessage({cmd, arg, id}),
/// ответ приходит в window.__kcReply(id, результат). Команды: start, stop, status, find, proxy.
@objc(LocalChatPlugin)
public class LocalChatPlugin: CAPPlugin, CAPBridgedPlugin, WKScriptMessageHandler {
    public let identifier = "LocalChatPlugin"
    public let jsName = "LocalChat"
    public let pluginMethods: [CAPPluginMethod] = [CAPPluginMethod(name: "cmd", returnType: CAPPluginReturnPromise)]

    override public func load() {
        // запасной путь — messageHandlers (если его ещё не вписал KamoxViewController)
        let add = { [weak self] in
            guard let self = self, let ucc = self.bridge?.webView?.configuration.userContentController else { return }
            ucc.removeScriptMessageHandler(forName: "kamoxLocal")
            ucc.add(KamoxWeakHandler(self), name: "kamoxLocal")
        }
        if Thread.isMainThread { add() } else { DispatchQueue.main.async(execute: add) }
    }

    /// страница, которая последней обращалась к модулю, — ей и отвечаем
    weak var lastWebView: WKWebView?

    static func assets(_ name: String) -> Data? {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "public") else { return nil }
        return try? Data(contentsOf: url)
    }

    private func info() -> String {
        guard let s = KamoxChatServer.shared else { return "{\"running\":false}" }
        let urls = KamoxChatServer.localAddresses().map { "\"http://\($0):\(s.port)/\"" }.joined(separator: ",")
        return "{\"running\":true,\"port\":\(s.port),\"clients\":\(s.clientCount),\"urls\":[\(urls)],\"local\":\"http://127.0.0.1:\(s.port)/\"}"
    }

    public func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String, let id = body["id"] as? String else { return }
        if let w = message.webView { lastWebView = w }
        let arg = body["arg"] as? String ?? ""
        // управлять сервером можно только со своих страниц, не со страниц чужих телефонов
        let o = message.frameInfo.securityOrigin
        let trusted = (o.protocol == "capacitor" && o.host == "localhost") || o.host == "kamox123.github.io"
        run(cmd, arg, trusted: trusted) { self.reply(id, $0) }
    }

    /// Основной путь: window.Capacitor.Plugins.LocalChat.cmd({cmd, arg}) → {json}. Capacitor пускает только свои страницы.
    @objc func cmd(_ call: CAPPluginCall) {
        let c = call.getString("cmd") ?? "", a = call.getString("arg") ?? ""
        // Capacitor зовёт модуль не из главного потока, а экран и сеть настраиваем из главного
        DispatchQueue.main.async { self.run(c, a, trusted: true) { call.resolve(["json": $0]) } }
    }

    func run(_ cmd: String, _ arg: String, trusted: Bool, _ done: @escaping (String) -> Void) {
        if !trusted && cmd != "status" { done("{\"error\":\"нет доступа\"}"); return }
        switch cmd {
        case "start":
            do {
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                _ = try KamoxChatServer.start(assets: LocalChatPlugin.assets, dir: dir)
                UIApplication.shared.isIdleTimerDisabled = true // экран не гаснет, пока чат работает
                done(info())
            } catch { done("{\"error\":\(KamoxJS.quote("Не удалось запустить чат: " + error.localizedDescription))}") }
        case "stop":
            KamoxChatServer.stopAll()
            UIApplication.shared.isIdleTimerDisabled = false
            done("{}")
        case "status":
            done(info())
        case "find":
            KamoxFinder.find { url in done("{\"url\":\(KamoxJS.quote(url ?? ""))}") }
        case "proxy":
            let hp = arg.split(separator: ":")
            guard hp.count >= 1, arg.range(of: "^[0-9.]{7,15}(:[0-9]{2,5})?$", options: .regularExpression) != nil else { done("{\"error\":\"нет доступа\"}"); return }
            do {
                let port = try KamoxProxy.start(assets: LocalChatPlugin.assets, host: String(hp[0]), port: UInt16(hp.count > 1 ? String(hp[1]) : "8080") ?? 8080)
                done("{\"port\":\(port)}")
            } catch { done("{\"error\":\(KamoxJS.quote(error.localizedDescription))}") }
        default:
            done("{\"error\":\"unknown\"}")
        }
    }

    private func reply(_ id: String, _ json: String) {
        DispatchQueue.main.async {
            (self.lastWebView ?? self.bridge?.webView)?.evaluateJavaScript("window.__kcReply && window.__kcReply(\(KamoxJS.quote(id)), \(json))", completionHandler: nil)
        }
    }

    // адреса школьного чата (свой iPhone и телефоны в локальной сети) открываем в приложении, а не в Safari
    override public func shouldOverrideLoad(_ navigationAction: WKNavigationAction) -> NSNumber? {
        guard let url = navigationAction.request.url, let host = url.host else { return nil }
        if host == "localhost" { return NSNumber(value: false) }
        if url.scheme == "http" && (host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.")) { return NSNumber(value: false) }
        return nil
    }
}

/// Без этой прокладки WebView держал бы модуль в памяти навсегда.
final class KamoxWeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(ucc, didReceive: message) }
}

enum KamoxJS {
    static func quote(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }
}

/// Главный экран приложения: обычный экран Capacitor + наш модуль школьного чата.
class KamoxViewController: CAPBridgeViewController {
    let kamoxPlugin = LocalChatPlugin()
    // мостик «kamoxLocal» вписываем в настройки WebView ДО загрузки страниц, иначе страница его не видит
    override open func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let c = super.webViewConfiguration(for: instanceConfiguration)
        c.userContentController.add(KamoxWeakHandler(kamoxPlugin), name: "kamoxLocal")
        c.userContentController.addUserScript(WKUserScript(source: "window.__kcNative = 'ios';", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        return c
    }
    override open func capacitorDidLoad() {
        // модуль мог уже подключиться сам (packageClassList) — тогда второй раз не регистрируем
        if bridge?.plugin(withName: "LocalChat") == nil { bridge?.registerPluginInstance(kamoxPlugin) }
    }
}
