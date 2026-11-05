import Foundation
import Darwin

// Discord on a Mac never sees Overwatch under Wine, so Recall sets the activity over the local socket every Discord
// client listens on (no account, no network).

enum DiscordAssets {
    // Discord's own Overwatch listing. Support: defaults write org.overwatch2mac.launcher discordApplicationID <digits>
    static let standardID="356875221078245376"
    static var applicationID:String {
        UserDefaults.standard.string(forKey:"discordApplicationID").flatMap { id in (17...20).contains(id.count) && id.allSatisfy { $0.isASCII && $0.isNumber } ? id : nil } ?? standardID
    }
    // Discord loads the badge itself; a fixed commit keeps installed cards working whatever main does.
    static let badge=URL(string:"https://raw.githubusercontent.com/\(Brand.repositoryPath)/0500e1b8540d5edc58fe1c7477c5977391c22990/app/Resources/AppIcon.png")!
}

enum PresenceCard {
    // In English: the people who see it may not read the player's language.
    static func activity(launched:Date)->[String:Any] {
        ["type":0,"timestamps":["start":Int(launched.timeIntervalSince1970)],
         "assets":["small_image":DiscordAssets.badge.absoluteString,"small_text":"Playing on Mac with \(Brand.name)"],
         "buttons":[["label":"Play Overwatch on Mac","url":Brand.repository.absoluteString]]]
    }
}

// A 4-byte opcode and a 4-byte length, little-endian, then the JSON.
enum DiscordFrame {
    static let handshake:UInt32=0,frame:UInt32=1,close:UInt32=2,ping:UInt32=3,pong:UInt32=4
    static func encode(_ opcode:UInt32,_ payload:Any)->Data? {
        guard JSONSerialization.isValidJSONObject(payload),let body=try? JSONSerialization.data(withJSONObject:payload) else { return nil }
        var data=Data()
        for value in [opcode,UInt32(body.count)] { withUnsafeBytes(of:value.littleEndian) { data.append(contentsOf:$0) } }
        return data+body
    }
}

struct DiscordFrameReader {
    struct Frame: Equatable { let opcode:UInt32;let body:Data }
    static let longest=1<<20
    private var bytes:[UInt8]=[]
    private(set) var broken=false
    mutating func feed(_ data:Data)->[Frame] {
        bytes+=data
        var frames:[Frame]=[]
        while bytes.count >= 8 {
            func word(_ at:Int)->UInt32 { UInt32(bytes[at])|UInt32(bytes[at+1])<<8|UInt32(bytes[at+2])<<16|UInt32(bytes[at+3])<<24 }
            let length=Int(word(4))
            if length > Self.longest { broken=true;bytes=[];break }
            guard bytes.count >= 8+length else { break }
            frames.append(Frame(opcode:word(0),body:Data(bytes[8..<8+length])))
            bytes.removeFirst(8+length)
        }
        return frames
    }
}

// Safe from any thread. Retries every half minute while there's a card.
final class DiscordIPC {
    private let queue=DispatchQueue(label:"org.overwatch2mac.discord-presence",qos:.utility)
    private let paths:[String],applicationID:String,pid:Int32
    // Discord takes five updates in twenty seconds.
    private let spacing:TimeInterval,burst:Int,window:TimeInterval,retryDelay:TimeInterval
    private var descriptor:Int32 = -1
    private var source:DispatchSourceRead?
    private var reader=DiscordFrameReader()
    private var ready=false,active=false,pending=false,retrying=false,refused=false
    private var wanted:[String:Any]?
    private var sent:[TimeInterval]=[]
    private static var clock:TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC))/1e9 }
    private var timer:DispatchWorkItem?,handshakeTimeout:DispatchWorkItem?
    private var tries=0,lean=0
    private var sentNonce:String?
    private let lock=NSLock()
    private var status:(connected:Bool,accepted:Bool,answer:String?)=(false,false,nil)
    private func locked<T>(_ body:()->T)->T { lock.lock();defer { lock.unlock() };return body() }
    var connected:Bool { locked { status.connected } }
    var accepted:Bool { locked { status.accepted } }
    // Outlives stop(), for the support report.
    var lastAnswer:String? { locked { status.answer } }
    var attempts:Int { queue.sync { tries } }

    init(applicationID:String=DiscordAssets.applicationID,paths:[String]?=nil,pid:Int32=getpid(),spacing:TimeInterval=0.5,burst:Int=5,window:TimeInterval=20,retry:TimeInterval=30) {
        self.applicationID=applicationID;self.pid=pid;self.spacing=spacing;self.burst=burst;self.window=window;self.retryDelay=retry
        self.paths=paths ?? Self.defaultPaths()
    }
    // This user's own temporary folder, which no other account can write to.
    static func defaultPaths()->[String] {
        let folder=NSTemporaryDirectory()
        return (0..<10).map { (folder.hasSuffix("/") ? folder : folder+"/")+"discord-ipc-\($0)" }
    }
    func set(_ activity:[String:Any]?) {
        queue.async {
            self.wanted=activity;self.pending=true;self.active=true
            if self.ready { self.flush() } else if self.descriptor < 0 && !self.refused { self.connect() }
        }
    }
    func stop() {
        queue.sync {
            if ready { send(DiscordFrame.frame,activityCommand(nil)) }
            active=false;pending=false;wanted=nil;refused=false;lean=0
            timer?.cancel();timer=nil
            disconnect()
        }
    }
    // A refused card goes again without button and badge, then with the timer alone.
    static func leaner(_ activity:[String:Any],_ step:Int)->[String:Any] {
        switch step {
        case 0: return activity
        case 1: var card=activity;card["buttons"]=nil;card["assets"]=nil;return card
        default: return activity.filter { $0.key == "type" || $0.key == "timestamps" }
        }
    }

    private func activityCommand(_ activity:[String:Any]?)->[String:Any] {
        let nonce=UUID().uuidString;sentNonce=nonce
        return ["cmd":"SET_ACTIVITY","args":["pid":pid,"activity":activity.map { Self.leaner($0,lean) as Any } ?? NSNull()],"nonce":nonce]
    }
    private func answered(_ text:String) { locked { status.answer=text } }
    private func flush() {
        guard ready,pending else { return }
        let now=Self.clock
        sent.removeAll { now-$0 >= window }
        var wait=sent.last.map { spacing-(now-$0) } ?? 0
        if sent.count >= burst { wait=max(wait,window-(now-sent[sent.count-burst])) }
        if wait > 0 {
            guard timer == nil else { return }
            let work=DispatchWorkItem { [weak self] in self?.timer=nil;self?.flush() }
            timer=work;queue.asyncAfter(deadline:.now()+wait,execute:work)
            return
        }
        pending=false;sent.append(now)
        if !send(DiscordFrame.frame,activityCommand(wanted)) { disconnect();scheduleRetry() }
    }
    private func connect() {
        guard active,descriptor < 0 else { return }
        tries+=1
        for path in paths {
            let fd=socket(AF_UNIX,SOCK_STREAM,0)
            guard fd >= 0 else { continue }
            var on:Int32=1
            setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&on,socklen_t(MemoryLayout<Int32>.size))
            var address=sockaddr_un()
            address.sun_family=sa_family_t(AF_UNIX)
            let capacity=MemoryLayout.size(ofValue:address.sun_path)
            guard path.utf8.count < capacity else { close(fd);continue }
            withUnsafeMutablePointer(to:&address.sun_path) { $0.withMemoryRebound(to:CChar.self,capacity:capacity) { _ = strlcpy($0,path,capacity) } }
            let result=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            // Only a program of this user's own counts as Discord.
            var owner:uid_t=0,group:gid_t=0
            guard result == 0,getpeereid(fd,&owner,&group) == 0,owner == getuid() else { close(fd);continue }
            _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)
            descriptor=fd;reader=DiscordFrameReader();ready=false
            let reading=DispatchSource.makeReadSource(fileDescriptor:fd,queue:queue)
            reading.setEventHandler { [weak self] in self?.readable() }
            // Closed only once the source lets go, so a new socket never reuses its number meanwhile.
            reading.setCancelHandler { close(fd) }
            reading.resume();source=reading
            guard send(DiscordFrame.handshake,["v":1,"client_id":applicationID]) else { disconnect();continue }
            let timeout=DispatchWorkItem { [weak self] in
                guard let self,!self.ready else { return }
                self.disconnect();self.scheduleRetry()
            }
            handshakeTimeout=timeout;queue.asyncAfter(deadline:.now()+5,execute:timeout)
            return
        }
        scheduleRetry()
    }
    private func readable() {
        var buffer=[UInt8](repeating:0,count:4096)
        let count=read(descriptor,&buffer,buffer.count)
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { disconnect();scheduleRetry();return }
        guard count > 0 else { return }
        let frames=reader.feed(Data(buffer[0..<count]))
        if reader.broken { disconnect();scheduleRetry();return }
        for frame in frames {
            switch frame.opcode {
            case DiscordFrame.ping: send(DiscordFrame.pong,(try? JSONSerialization.jsonObject(with:frame.body)) ?? [String:Any]())
            case DiscordFrame.close:
                let code=(try? JSONSerialization.jsonObject(with:frame.body) as? [String:Any])?["code"] as? Int
                answered("closed_\(code.map(String.init) ?? "unknown")")
                // An unknown listing, version or encoding won't change by asking again; 4002 is asking too often.
                if let code,[4000,4004,4005].contains(code) { refused=true }
                disconnect();scheduleRetry(longer:code == 4002);return
            case DiscordFrame.frame:
                guard let message=try? JSONSerialization.jsonObject(with:frame.body) as? [String:Any] else { break }
                if message["evt"] as? String == "READY" {
                    handshakeTimeout?.cancel();ready=true;pending=true;lean=0
                    locked { status.connected=true;status.answer="ready" }
                    flush()
                } else if message["cmd"] as? String == "SET_ACTIVITY" {
                    let taken=message["evt"] as? String != "ERROR"
                    locked { status.accepted=taken }
                    if taken { answered(lean == 0 ? "accepted" : "accepted_lean_\(lean)") }
                    else {
                        let code=(message["data"] as? [String:Any])?["code"] as? Int
                        answered("refused_\(code.map(String.init) ?? "unknown")")
                        if message["nonce"] as? String == sentNonce,wanted != nil,lean < 2 { lean+=1;pending=true;flush() }
                    }
                }
            default: break
            }
        }
    }
    @discardableResult private func send(_ opcode:UInt32,_ payload:Any)->Bool {
        guard descriptor >= 0,let data=DiscordFrame.encode(opcode,payload) else { return false }
        var sent=0
        return data.withUnsafeBytes { raw -> Bool in
            while sent < data.count {
                let n=write(descriptor,raw.baseAddress!+sent,data.count-sent)
                if n > 0 { sent+=n } else if n < 0 && errno == EINTR { continue }
                // A full socket is waited on, two seconds at most.
                else if n < 0 && errno == EAGAIN {
                    var room=pollfd(fd:descriptor,events:Int16(POLLOUT),revents:0)
                    if poll(&room,1,2000) <= 0 { return false }
                } else { return false }
            }
            return true
        }
    }
    private func disconnect() {
        source?.cancel();source=nil;descriptor = -1
        handshakeTimeout?.cancel();handshakeTimeout=nil
        ready=false
        locked { status.connected=false;status.accepted=false }
    }
    private func scheduleRetry(longer:Bool=false) {
        guard active,!retrying,!refused else { return }
        retrying=true
        queue.asyncAfter(deadline:.now()+retryDelay*(longer ? 10 : 1)) { [weak self] in
            guard let self else { return }
            self.retrying=false
            guard self.active,self.descriptor < 0 else { return }
            self.pending=true;self.connect()
        }
    }
}
