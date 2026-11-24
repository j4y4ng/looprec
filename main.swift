import AVFoundation
import UIKit

// 循环录音：持续录制，每 10 分钟分段，只保留最近 10 小时
final class LoopRec: NSObject, AVAudioRecorderDelegate {
    static let shared = LoopRec()
    private(set) var running = false
    private var rec: AVAudioRecorder?
    private var timer: Timer?
    private let dir: URL

    private override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    var files: [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return all.filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var totalBytes: Int64 {
        files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        try newSegment()
        running = true
        UserDefaults.standard.set(true, forKey: "auto")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        rec?.stop()
        rec = nil
        running = false
        UserDefaults.standard.set(false, forKey: "auto")
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func newSegment() throws {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let url = dir.appendingPathComponent("rec_\(fmt.string(from: Date())).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        guard r.record() else {
            throw NSError(domain: "LoopRec", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法开始录音，请检查麦克风权限"])
        }
        rec = r
    }
    private func tick() {
        guard running else { return }
        if let r = rec, r.currentTime >= 600 {
            r.stop()
            try? newSegment()
            prune()
        }
        let d = UIDevice.current
        if d.batteryLevel > 0 && d.batteryLevel <= 0.1 && d.batteryState == .unplugged {
            stop()
        }
        NotificationCenter.default.post(name: .loopRecChanged, object: nil)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-36000)
        let list = files
        var keep: [URL] = []
        for u in list {
            if let cur = rec?.url, cur == u { keep.append(u); continue }
            let t = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if t < cutoff { try? FileManager.default.removeItem(at: u) } else { keep.append(u) }
        }
        if keep.count > 70 {
            for u in keep.prefix(keep.count - 70) {
                if let cur = rec?.url, cur == u { continue }
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            try? self?.newSegment()
        }
    }
}

extension Notification.Name {
    static let loopRecChanged = Notification.Name("loopRecChanged")
}
final class RootVC: UIViewController {
    private let status = UILabel()
    private let detail = UILabel()
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let title = UILabel()
        title.text = "循环录音"
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textAlignment = .center

        status.font = .systemFont(ofSize: 17, weight: .medium)
        status.textAlignment = .center

        detail.font = .systemFont(ofSize: 14)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0

        button.layer.cornerRadius = 14
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 56).isActive = true
        button.addTarget(self, action: #selector(tap), for: .touchUpInside)

        let note = UILabel()
        note.text = "每 10 分钟一个文件，只保留最近 10 小时，超出后自动删除最早的录音。"
        note.font = .systemFont(ofSize: 12)
        note.textColor = .tertiaryLabel
        note.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, status, detail, button, note])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: .loopRecChanged, object: nil)
        refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if UserDefaults.standard.bool(forKey: "auto"), !LoopRec.shared.running {
            try? LoopRec.shared.start()
        }
    }

    @objc private func tap() {
        let engine = LoopRec.shared
        if engine.running {
            engine.stop()
        } else {
            do {
                try engine.start()
            } catch {
                let alert = UIAlertController(title: "无法开始录音",
                                              message: error.localizedDescription,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                present(alert, animated: true)
            }
        }
        refresh()
    }

    @objc private func refresh() {
        let engine = LoopRec.shared
        status.text = engine.running ? "● 正在录音" : "○ 已停止"
        status.textColor = engine.running ? .systemRed : .secondaryLabel
        button.setTitle(engine.running ? "停止录音" : "开始录音", for: .normal)
        button.backgroundColor = engine.running ? .systemRed : .systemBlue
        let mb = Double(engine.totalBytes) / 1024 / 1024
        detail.text = String(format: "片段 %d 个 ｜ 占用 %.1f MB", engine.files.count, mb)
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = RootVC()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                  NSStringFromClass(AppDelegate.self))
