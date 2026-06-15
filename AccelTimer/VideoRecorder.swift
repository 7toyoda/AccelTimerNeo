import AVFoundation
import CoreText
import CoreGraphics
import UIKit

// MARK: - Overlay snapshot (lock-protected)

private struct OverlaySnapshot {
    var speed: Double = 0
    var time: TimeInterval = 0
    var splits: [Double?] = [nil, nil, nil, nil]
}

// MARK: - VideoRecorder

final class VideoRecorder: NSObject {

    // MARK: - Callbacks (main thread)
    var onSaved: ((String) -> Void)?  // filename (not full path)
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?        // キャプチャセッション構築完了（プリロール開始の合図）
    var recordedPeakKmh: Double = 0   // 録画中のピーク速度（保存可否判定用。engineリセット後も保持）

    // MARK: - Lock-protected shared state (main ↔ frameQ)
    private let lock = NSLock()
    private var overlay = OverlaySnapshot()
    private var _wantsRecording = false

    private var wantsRecording: Bool {
        get { lock.withLock { _wantsRecording } }
        set { lock.withLock { _wantsRecording = newValue } }
    }

    func updateOverlay(speed: Double, time: TimeInterval, splits: [Double?]) {
        lock.withLock { overlay = OverlaySnapshot(speed: speed, time: time, splits: splits) }
    }

    // MARK: - Private (sessionQ or frameQ only)
    private let sessionQ = DispatchQueue(label: "com.acceltimer.video.session", qos: .userInitiated)
    private let frameQ  = DispatchQueue(label: "com.acceltimer.video.frame",   qos: .userInitiated)

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?  // 向き変更用
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?  // nil = 音声なし
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingActive = false  // frameQ only
    private var outputURL: URL?
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - プリロール（READYから録画→発進点へトリミング）用の状態（frameQ/captureOutput内のみ）
    private var sessionStartWall: Date?     // 現セグメントの先頭フレームの実時刻（トリミング基準）
    private var segmentStartPTS: CMTime = .zero
    private var launchLocked = false        // 発進検知後は巻き取りを止めてセグメントを保持
    private var curVideoWidth = 1920
    private var curVideoHeight = 1080
    private var curAudio = false
    // 巡回保持の上限秒数。これを超えても未発進なら古いセグメントを破棄して新規録画（発進は常に収録）。
    // 録画は「停車確認後」に開始する(#1)ため、停車からこの秒数以内に発進すれば巻き取りが起きず
    // 必ず0km/hから収録できる。境界に当たって発進の出だしを取りこぼす確率も rollSeconds に反比例で低減。
    // 一時ファイルは概ね rollSeconds 分（1080p ≈ 2〜3MB/秒）で、保存/破棄後に削除される。
    private static let rollSeconds = 90.0

    // MARK: - Temp cleanup

    /// 一時ディレクトリに取り残された録画一時ファイル(accel_*.mov)を削除する。
    /// 通常は保存/破棄/巻き取りで都度削除されるが、録画中のクラッシュ/強制終了で残った分を掃除する。
    /// **アプリ起動時に1回だけ呼ぶこと**（録画中に呼ぶと進行中の一時ファイルを消す恐れがあるため）。
    static func pruneOrphanTempFiles() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let files = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for url in files where url.lastPathComponent.hasPrefix("accel_") && url.pathExtension == "mov" {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Authorization

    static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default:             return false
        }
    }

    // MARK: - Session lifecycle

    func prepareSession(withAudio: Bool = false) {
        sessionQ.async { [weak self] in self?.buildSession(withAudio: withAudio) }
    }

    private func buildSession(withAudio: Bool) {
        guard captureSession == nil else { return }
        let sess = AVCaptureSession()
        sess.beginConfiguration()
        sess.sessionPreset = .hd1920x1080

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input  = try? AVCaptureDeviceInput(device: device),
            sess.canAddInput(input)
        else { return }
        sess.addInput(input)

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: frameQ)
        guard sess.canAddOutput(out) else { return }
        sess.addOutput(out)

        // 音声入力（許可済みの場合のみ追加）
        if withAudio,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput  = try? AVCaptureDeviceInput(device: audioDevice),
           sess.canAddInput(audioInput) {
            sess.addInput(audioInput)
            let audioOut = AVCaptureAudioDataOutput()
            audioOut.setSampleBufferDelegate(self, queue: frameQ)
            if sess.canAddOutput(audioOut) { sess.addOutput(audioOut) }
        }

        sess.commitConfiguration()
        // 省電力：ビルド時はセッションを起動しない。停車確認後のプリロール開始
        // （startRecording）で初めて起動し、録画の保存/破棄で停止する。
        captureSession = sess
        videoOutput = out
        DispatchQueue.main.async { [weak self] in self?.onReady?() }

        // 通話・音楽アプリ等によるセッション割り込みを検知して録画を安全に保存
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: sess,
            queue: nil
        ) { [weak self] _ in
            self?.stopAndSave()
        }
    }

    /// 省電力：録画終了後にキャプチャセッションを停止する（次のプリロールで再起動）。
    /// teardown と異なりセッション構成は保持するため、再起動のコストが小さい。
    private func pauseSessionRunning() {
        sessionQ.async { [weak self] in
            guard let s = self?.captureSession, s.isRunning else { return }
            s.stopRunning()
        }
    }

    func teardown() {
        wantsRecording = false
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        sessionQ.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
            self?.videoOutput = nil
        }
    }

    // MARK: - Recording control

    /// READY（停車・準備完了）で呼ぶ。発進前から録画を始め、発進点は保存時にトリミングする。
    func startRecording(audio: Bool = false, rotationAngle: CGFloat = 0) {
        let isPortrait  = (rotationAngle == 90 || rotationAngle == 270)
        curVideoWidth  = isPortrait ? 1080 : 1920
        curVideoHeight = isPortrait ? 1920 : 1080
        curAudio       = audio
        launchLocked   = false

        frameQ.async { [weak self] in self?.makeWriter() }
        // 回転をsessionQで適用してからwantsRecordingをセットする。
        // 先にtrueにするとframeQが回転前（未補正サイズ）のフレームをライターに送り込み映像が壊れる。
        sessionQ.async { [weak self] in
            guard let self else { return }
            // 省電力：プリロール開始時にキャプチャセッションを起動（待機中は止めてある）
            if let s = self.captureSession, !s.isRunning { s.startRunning() }
            if let conn = self.videoOutput?.connection(with: .video),
               conn.isVideoRotationAngleSupported(rotationAngle) {
                conn.videoRotationAngle = rotationAngle
            }
            self.wantsRecording = true
        }
    }

    /// 発進検知時に呼ぶ。以降は巻き取り（古いセグメント破棄）を止め、現セグメントを保持する。
    func lockForRun() {
        frameQ.async { [weak self] in self?.launchLocked = true }
    }

    /// 新しい AVAssetWriter を作って差し替える（frameQ で呼ぶ）。次のフレームでセッション開始される。
    private func makeWriter() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("accel_\(Int(Date().timeIntervalSince1970 * 1000)).mov")
        guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: curVideoWidth,
            AVVideoHeightKey: curVideoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // キーフレームを密(約1秒)にして、保存時のトリミング位置が発進点に近くなるようにする
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
        let wi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        wi.expectsMediaDataInRealTime = true
        wi.transform = .identity

        let adp = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: wi,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        guard wr.canAdd(wi) else { return }
        wr.add(wi)

        var awi: AVAssetWriterInput? = nil
        if curAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if wr.canAdd(a) { wr.add(a); awi = a }
        }

        outputURL        = url
        writer           = wr
        writerInput      = wi
        audioWriterInput = awi
        adaptor          = adp
        recordingActive  = false
        sessionStartWall = nil
    }

    /// 巻き取り：現セグメントを破棄して新規録画に切り替える（発進前のみ・frameQ）。
    private func rollOver() {
        let oldWriter = writer
        let oldURL    = outputURL
        writerInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        oldWriter?.finishWriting {
            if let u = oldURL { try? FileManager.default.removeItem(at: u) }
        }
        makeWriter()
    }

    func stopAndSave() {
        wantsRecording = false
        pauseSessionRunning()
        frameQ.async { [weak self] in
            guard let self else { return }
            guard self.recordingActive else {
                // startRecording 後、最初のフレーム到着前に呼ばれた場合はキャンセル扱いで片付ける
                self.writer?.cancelWriting()
                if let url = self.outputURL { try? FileManager.default.removeItem(at: url) }
                self.writer = nil; self.writerInput = nil
                self.audioWriterInput = nil; self.adaptor = nil; self.outputURL = nil
                return
            }
            self.recordingActive = false
            self.audioWriterInput?.markAsFinished()
            self.writerInput?.markAsFinished()
            // finishWriting は任意スレッドでコールバックされる。self プロパティを先にクリアして
            // ローカル変数経由で完了させることで、次の startRecording の writer/outputURL を
            // コールバックが誤って nil 化するのを防ぐ。
            let writerToFinish = self.writer
            let savedURL       = self.outputURL
            self.writer = nil; self.writerInput = nil
            self.audioWriterInput = nil; self.adaptor = nil; self.outputURL = nil
            writerToFinish?.finishWriting { [weak self] in
                guard let url = savedURL else { return }
                self?.saveToDocuments(url: url)
            }
        }
    }

    func cancelAndDiscard() {
        wantsRecording = false
        pauseSessionRunning()
        frameQ.async { [weak self] in
            guard let self else { return }
            if self.recordingActive {
                self.recordingActive = false
                self.audioWriterInput?.markAsFinished()
                self.writerInput?.markAsFinished()
            }
            // recordingActive の有無に関わらず常にキャンセル（stopAndSave と対称的に）
            self.writer?.cancelWriting()
            if let url = self.outputURL { try? FileManager.default.removeItem(at: url) }
            self.writer = nil
            self.writerInput = nil
            self.audioWriterInput = nil
            self.adaptor = nil
            self.outputURL = nil
            self.sessionStartWall = nil
            self.launchLocked = false
        }
    }

    /// 録画を停止し、発進点(launchWall)の leadIn 秒前から末尾までにトリミングして保存する。
    /// launchWall が nil（発進時刻不明）の場合は全体を保存する。一時ファイルは保存後に削除。
    func stopAndSaveTrimmed(launchWall: Date?, leadIn: Double) {
        wantsRecording = false
        pauseSessionRunning()
        frameQ.async { [weak self] in
            guard let self else { return }
            guard self.recordingActive else {
                self.writer?.cancelWriting()
                if let url = self.outputURL { try? FileManager.default.removeItem(at: url) }
                self.writer = nil; self.writerInput = nil
                self.audioWriterInput = nil; self.adaptor = nil; self.outputURL = nil
                self.sessionStartWall = nil; self.launchLocked = false
                return
            }
            self.recordingActive = false
            self.audioWriterInput?.markAsFinished()
            self.writerInput?.markAsFinished()
            let writerToFinish = self.writer
            let savedURL       = self.outputURL
            let startWall      = self.sessionStartWall
            self.writer = nil; self.writerInput = nil
            self.audioWriterInput = nil; self.adaptor = nil; self.outputURL = nil
            self.sessionStartWall = nil; self.launchLocked = false
            writerToFinish?.finishWriting { [weak self] in
                guard let url = savedURL else { return }
                var trimStart = 0.0
                if let lw = launchWall, let sw = startWall {
                    trimStart = max(0, lw.timeIntervalSince(sw) - leadIn)
                }
                self?.trimAndSave(url: url, startSeconds: trimStart)
            }
        }
    }

    /// url の動画を startSeconds から末尾までトリミングして recordings に保存し、元(一時)を削除する。
    private func trimAndSave(url: URL, startSeconds: Double) {
        let asset = AVURLAsset(url: url)
        let startT = CMTime(seconds: startSeconds, preferredTimescale: 600)
        // トリミング不要（先頭付近）または不正な場合は全体保存にフォールバック
        guard startSeconds > 0.1,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { saveToDocuments(url: url); return }

        let fm = FileManager.default
        let recordingsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings", isDirectory: true)
        try? fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let filename = url.lastPathComponent
        let destURL  = recordingsDir.appendingPathComponent(filename)
        try? fm.removeItem(at: destURL)

        export.outputURL = destURL
        export.outputFileType = .mov
        // startSeconds から末尾まで。実長より大きい duration を渡すと自動的に実長へクランプされるため、
        // deprecated な asset.duration を読まずに済む（先頭→末尾のトリミング）。
        export.timeRange = CMTimeRange(start: startT,
                                       duration: CMTime(seconds: 36000, preferredTimescale: 600))
        export.exportAsynchronously { [weak self] in
            if export.status == .completed {
                try? fm.removeItem(at: url)   // 一時ファイル削除
                DispatchQueue.main.async { self?.onSaved?(filename) }
            } else {
                // トリミング失敗時は全体を保存（取りこぼし防止）
                self?.saveToDocuments(url: url)
            }
        }
    }

    // MARK: - Documents storage

    private func saveToDocuments(url: URL) {
        let fm = FileManager.default
        let recordingsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings", isDirectory: true)
        do {
            try fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            let filename = url.lastPathComponent
            let destURL  = recordingsDir.appendingPathComponent(filename)
            try fm.moveItem(at: url, to: destURL)
            DispatchQueue.main.async { self.onSaved?(filename) }
        } catch {
            try? fm.removeItem(at: url)
            DispatchQueue.main.async { self.onError?(error.localizedDescription) }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard wantsRecording else { return }

        // 音声サンプル
        if output is AVCaptureAudioDataOutput {
            guard recordingActive,
                  let awi = audioWriterInput,
                  awi.isReadyForMoreMediaData else { return }
            awi.append(sampleBuffer)
            return
        }

        // 映像サンプル
        guard let wr = writer, let wi = writerInput, let adp = adaptor,
              let pixBuf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !recordingActive {
            guard wr.startWriting() else { return }
            wr.startSession(atSourceTime: ts)
            recordingActive = true
            segmentStartPTS = ts
            sessionStartWall = Date()   // トリミング基準（発進実時刻との差分でオフセット算出）
        }

        // 発進前のプリロール中は、一定時間を超えたら古いセグメントを破棄して巻き取る
        // （発進は常に現セグメントに収録される。launchLocked 後は巻き取らない）。
        if !launchLocked,
           CMTimeGetSeconds(CMTimeSubtract(ts, segmentStartPTS)) > Self.rollSeconds {
            rollOver()
            return
        }

        guard wi.isReadyForMoreMediaData else { return }

        let snap: OverlaySnapshot = lock.withLock { overlay }
        drawOverlay(on: pixBuf, snap: snap)
        adp.append(pixBuf, withPresentationTime: ts)
    }
}

// MARK: - Overlay rendering

// MARK: - Overlay color helpers (UIKit-free)

private extension CGColor {
    static let overlayWhite  = CGColor(red: 1,    green: 1,    blue: 1,    alpha: 1)
    static let overlayYellow = CGColor(red: 1,    green: 1,    blue: 0,    alpha: 1)
    static let overlayGray   = CGColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
    static let overlayGreen  = CGColor(red: 0.2,  green: 0.78, blue: 0.35, alpha: 1)
    static let overlayDim    = CGColor(gray: 0.5, alpha: 1)
}

// MARK: - Overlay rendering

private extension VideoRecorder {

    // フォントは起動時に一度だけ生成してキャッシュ（30fps × 6呼び出し分の生成コストを削減）。
    // 固定幅フォント(SF Mono)で数字がブレないようにし、大きめに表示する。
    static let fontSpeed      = makeCTFont(size: 110, bold: true)
    static let fontTime       = makeCTFont(size: 104, bold: true)
    static let fontSplitLabel = makeCTFont(size: 34,  bold: false)
    static let fontSplitValue = makeCTFont(size: 76,  bold: true)
    static let fontSplitUnit  = makeCTFont(size: 42,  bold: true)   // 速度帯値の後ろに付ける小さい単位「s」

    private static func makeCTFont(size: CGFloat, bold: Bool) -> CTFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .heavy : .medium) as CTFont
    }

    func drawOverlay(on pixBuf: CVPixelBuffer, snap: OverlaySnapshot) {
        CVPixelBufferLockBaseAddress(pixBuf, [])
        defer { CVPixelBufferUnlockBaseAddress(pixBuf, []) }

        let pw = CVPixelBufferGetWidth(pixBuf)
        let ph = CVPixelBufferGetHeight(pixBuf)
        guard let base = CVPixelBufferGetBaseAddress(pixBuf) else { return }

        guard let ctx = CGContext(
            data: base, width: pw, height: ph, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixBuf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        // CoreGraphics の原点を左上に変換
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: 1, y: -1)

        let W = CGFloat(pw)
        let stripH: CGFloat = 410
        let y0 = CGFloat(ph) - stripH
        let pad: CGFloat = 40

        // 半透明ストリップ
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.66))
        ctx.fill(CGRect(x: 0, y: y0, width: W, height: stripH))

        // 重要：drawText の y はテキストの「ベースライン」で、グリフは上方向に伸びる。
        // 各段はベースラインで指定し、上のフォント高さ分が枠内に収まるよう配置する。
        // 速度→タイム→スプリット(ラベル+値) を均等な間隔で、速度帯は時間に近づけて大きく表示。

        // 1段目：速度（ベースライン y0+116 ＝ 110pt が枠上端に収まる）
        drawText(String(format: "%.1f km/h", snap.speed),
                 ctx: ctx, at: CGPoint(x: pad, y: y0 + 116),
                 font: Self.fontSpeed, color: .overlayWhite)

        // 2段目：タイム（ベースライン y0+236）。単位は言語非依存の「s」（km/h と同じく万国共通）
        drawText(formatTime(snap.time) + " s",
                 ctx: ctx, at: CGPoint(x: pad, y: y0 + 236),
                 font: Self.fontTime, color: .overlayYellow)

        // 3段目：スプリット 4 列。ラベル(小)の下に値(大)＋小さい単位「s」を置く。
        let labels = ["0→40", "0→60", "0→80", "0→100"]
        let colW = (W - pad * 2) / 4
        let labelBaseY = y0 + 300   // ラベルのベースライン（時間段に近づけて上に）
        let valueBaseY = labelBaseY + 84   // 値のベースライン（ラベルのすぐ下・大きく）
        for i in 0..<4 {
            let cx = pad + colW * CGFloat(i)
            drawText(labels[i], ctx: ctx, at: CGPoint(x: cx, y: labelBaseY),
                     font: Self.fontSplitLabel, color: .overlayGray)
            guard let s = snap.splits[i] else {
                drawText("--", ctx: ctx, at: CGPoint(x: cx, y: valueBaseY),
                         font: Self.fontSplitValue, color: .overlayDim)
                continue
            }
            let val = String(format: "%.3f", s)
            // 値＋単位「s」が列幅に収まる最大サイズを選ぶ。
            // 通常(横画面/5桁)は基準サイズ、縦画面で桁が増えた時だけ自動縮小して列の重なりを防ぐ。
            var vFont = Self.fontSplitValue
            var uFont = Self.fontSplitUnit
            var gap: CGFloat = 8
            let needed = textWidth(val, font: vFont) + gap + textWidth("s", font: uFont)
            let avail = colW - 16
            if needed > avail {
                let scale = avail / needed
                vFont = Self.makeCTFont(size: 76 * scale, bold: true)
                uFont = Self.makeCTFont(size: 42 * scale, bold: true)
                gap *= scale
            }
            drawText(val, ctx: ctx, at: CGPoint(x: cx, y: valueBaseY),
                     font: vFont, color: .overlayGreen)
            let w = textWidth(val, font: vFont)
            drawText("s", ctx: ctx, at: CGPoint(x: cx + w + gap, y: valueBaseY),
                     font: uFont, color: .overlayGray)
        }
    }

    /// テキストの描画幅（単位を値の直後に置くために使用）
    func textWidth(_ text: String, font: CTFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    func drawText(_ text: String, ctx: CGContext, at pt: CGPoint,
                  font: CTFont, color: CGColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName            as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        // CTM が y 軸反転されているため textMatrix で打ち消してテキストを正立させる
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        ctx.textPosition = pt
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t); let ms = Int((t - Double(s)) * 1000)
        return s < 60
            ? String(format: "%d.%03d", s, ms)
            : String(format: "%d:%02d.%03d", s / 60, s % 60, ms)
    }
}
