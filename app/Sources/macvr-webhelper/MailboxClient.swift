import Foundation

// One mailbox per connection, like the pages' CVRMailbox.
final class MailboxClient: NSObject, URLSessionWebSocketDelegate {
    let port: Int
    let name: String
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!

    init(port: Int, name: String) {
        self.port = port
        self.name = name
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    }

    func connect() {
        let t = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        t.maximumMessageSize = 16 << 20
        task = t
        t.resume()
        t.send(.string("mailbox_open \(name)")) { _ in }
        receive()
    }

    func send(to mailbox: String, _ json: String) {
        task?.send(.string("mailbox_send \(mailbox) \(json)")) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let s)):
                if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                    self.onMessage?(obj)
                }
                self.receive()
            case .success:
                self.receive()
            case .failure(let e):
                log("mailbox \(self.name): \(e.localizedDescription)")
                self.onClose?()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?()
    }
}
