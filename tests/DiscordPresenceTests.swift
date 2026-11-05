import Foundation
import Darwin

// DiscordPresence.swift against a fake Discord on a temporary socket. Build and run:
//   swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/Brand.swift app/Sources/Localization.swift \
//     app/Sources/DiscordPresence.swift tests/DiscordPresenceTests.swift -o runtime/phase-3/discord-presence-tests
//   runtime/phase-3/discord-presence-tests

func wait(_ seconds:Double=5,_ done:()->Bool)->Bool {
    let end=Date().addingTimeInterval(seconds)
    while Date() < end { if done() { return true };Thread.sleep(forTimeInterval:0.02) }
    return done()
}

final class FakeDiscord {
    let path:String
    private let listener:Int32
    init() {
        let folder=NSTemporaryDirectory()+"ow2-discord-\(getpid())-\(UInt32.random(in:0..<1_000_000))/"
        try! FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
        path=folder+"discord-ipc-0"
        listener=socket(AF_UNIX,SOCK_STREAM,0)
        var address=sockaddr_un()
        address.sun_family=sa_family_t(AF_UNIX)
        let capacity=MemoryLayout.size(ofValue:address.sun_path)
        withUnsafeMutablePointer(to:&address.sun_path) { $0.withMemoryRebound(to:CChar.self,capacity:capacity) { _ = strlcpy($0,path,capacity) } }
        let bound=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        precondition(bound == 0 && Darwin.listen(listener,4) == 0)
    }
    deinit {
        Darwin.close(listener)
        try? FileManager.default.removeItem(atPath:(path as NSString).deletingLastPathComponent)
    }
    func accept(_ milliseconds:Int32=5000)->Int32? {
        var poller=pollfd(fd:listener,events:Int16(POLLIN),revents:0)
        guard poll(&poller,1,milliseconds) > 0 else { return nil }
        let fd=Darwin.accept(listener,nil,nil)
        return fd >= 0 ? fd : nil
    }
    private func read(_ fd:Int32,_ count:Int,_ milliseconds:Int32)->[UInt8]? {
        var bytes=[UInt8]()
        while bytes.count < count {
            var poller=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            guard poll(&poller,1,milliseconds) > 0 else { return nil }
            var chunk=[UInt8](repeating:0,count:count-bytes.count)
            let n=Darwin.read(fd,&chunk,chunk.count)
            guard n > 0 else { return nil }
            bytes+=chunk[0..<n]
        }
        return bytes
    }
    func frame(_ fd:Int32,_ milliseconds:Int32=5000)->(opcode:UInt32,json:[String:Any])? {
        guard let head=read(fd,8,milliseconds) else { return nil }
        let length=Int(head[4])|Int(head[5])<<8|Int(head[6])<<16|Int(head[7])<<24
        guard let body=read(fd,length,milliseconds),let json=try? JSONSerialization.jsonObject(with:Data(body)) as? [String:Any] else { return nil }
        return (UInt32(head[0])|UInt32(head[1])<<8|UInt32(head[2])<<16|UInt32(head[3])<<24,json)
    }
    func send(_ fd:Int32,_ opcode:UInt32,_ json:[String:Any]) {
        let data=DiscordFrame.encode(opcode,json)!
        _ = data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress!,data.count) }
    }
    func welcome(_ fd:Int32)->[String:Any]? {
        guard let hello=frame(fd),hello.opcode == DiscordFrame.handshake else { return nil }
        send(fd,DiscordFrame.frame,["cmd":"DISPATCH","evt":"READY","data":["v":1]])
        return hello.json
    }
    func card(_ fd:Int32,_ milliseconds:Int32=5000)->Any?? {
        guard let message=frame(fd,milliseconds),message.opcode == DiscordFrame.frame,message.json["cmd"] as? String == "SET_ACTIVITY",
              let args=message.json["args"] as? [String:Any] else { return nil }
        return .some(args["activity"])
    }
    func closed(_ fd:Int32)->Bool {
        var poller=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
        var byte:UInt8=0
        return poll(&poller,1,5000) > 0 && Darwin.read(fd,&byte,1) == 0
    }
}
func details(_ card:Any??)->String? { ((card ?? nil) as? [String:Any])?["details"] as? String }

@main struct DiscordPresenceTests {
    static func main() {
        frames();card();connection();reconnect();absent();rate();refusals()
        print("PASS: Discord frames, the card, the Discord socket")
    }

    static func card() {
        let opened=Date(timeIntervalSince1970:1_762_000_000.7)
        let card=PresenceCard.activity(launched:opened)
        precondition(card["type"] as? Int == 0 && (card["timestamps"] as? [String:Int])?["start"] == 1_762_000_000 && card["details"] == nil && card["state"] == nil)
        let assets=card["assets"] as? [String:String],buttons=card["buttons"] as? [[String:String]]
        precondition(assets?["small_text"] == "Playing on Mac with \(Brand.name)" && assets?["large_image"] == nil,"\(String(describing:assets))")
        let badge=assets?["small_image"] ?? ""
        precondition(badge.hasPrefix("https://raw.githubusercontent.com/\(Brand.repositoryPath)/") && badge.hasSuffix("/app/Resources/AppIcon.png") && badge.utf16.count <= 300)
        precondition(FileManager.default.fileExists(atPath:"app/Resources/AppIcon.png"),"run from the repository root")
        precondition(buttons?.count == 1 && buttons?[0]["label"] == "Play Overwatch on Mac" && (buttons?[0]["label"]?.utf16.count ?? 99) <= 32
                     && buttons?[0]["url"] == Brand.repository.absoluteString)
        precondition(DiscordAssets.applicationID == DiscordAssets.standardID && JSONSerialization.isValidJSONObject(card))
    }

    static func frames() {
        let body=["cmd":"SET_ACTIVITY"]
        let one=DiscordFrame.encode(DiscordFrame.frame,body)!
        precondition(Array(one[0..<4]) == [1,0,0,0] && Int(one[4]) == one.count-8 && one[5] == 0)
        var reader=DiscordFrameReader()
        var got:[DiscordFrameReader.Frame]=[]
        for byte in one { got+=reader.feed(Data([byte])) }
        precondition(got.count == 1 && got[0].opcode == 1 && (try! JSONSerialization.jsonObject(with:got[0].body) as! [String:String]) == body)
        let ping=DiscordFrame.encode(DiscordFrame.ping,["n":1])!
        got=reader.feed(ping+one)
        precondition(got.map(\.opcode) == [3,1])
        var bad=DiscordFrameReader()
        _ = bad.feed(Data([1,0,0,0,0,0,0,0x7f]))
        precondition(bad.broken)
        precondition(DiscordFrame.encode(1,["a":Date()]) == nil)
    }

    static func connection() {
        let server=FakeDiscord()
        let client=DiscordIPC(applicationID:"1234",paths:[server.path],pid:4242,spacing:0.5,burst:100,retry:0.3)
        client.set(["type":0,"details":"In Menus"])
        guard let fd=server.accept(),let hello=server.welcome(fd) else { preconditionFailure("no handshake") }
        precondition(hello["v"] as? Int == 1 && hello["client_id"] as? String == "1234")
        guard let first=server.frame(fd) else { preconditionFailure("no card") }
        precondition(first.opcode == DiscordFrame.frame && first.json["cmd"] as? String == "SET_ACTIVITY" && !(first.json["nonce"] as? String ?? "").isEmpty)
        let args=first.json["args"] as! [String:Any]
        precondition(args["pid"] as? Int == 4242 && (args["activity"] as! [String:Any])["details"] as? String == "In Menus")
        precondition(wait { client.connected } && !client.accepted)
        server.send(fd,DiscordFrame.frame,["cmd":"SET_ACTIVITY","evt":NSNull(),"data":[:],"nonce":first.json["nonce"]!])
        precondition(wait { client.accepted })
        server.send(fd,DiscordFrame.frame,["cmd":"SET_ACTIVITY","evt":"ERROR","data":["code":4000,"message":"no"],"nonce":"n"])
        precondition(wait { !client.accepted } && client.connected)
        server.send(fd,DiscordFrame.ping,["nonce":"x"])
        precondition(server.frame(fd)?.opcode == DiscordFrame.pong)
        client.set(["details":"one"]);client.set(["details":"two"])
        let asked=Date()
        precondition(details(server.card(fd)) == "two" && Date().timeIntervalSince(asked) > 0.05)
        client.stop()
        precondition((server.card(fd) ?? nil) is NSNull && server.closed(fd) && !client.connected)
    }

    static func reconnect() {
        let server=FakeDiscord()
        let client=DiscordIPC(applicationID:"1234",paths:[server.path],spacing:0.1,burst:100,retry:0.3)
        client.set(["details":"A"])
        guard let first=server.accept(),server.welcome(first) != nil else { preconditionFailure("no handshake") }
        precondition(details(server.card(first)) == "A")
        Darwin.close(first)
        client.set(["details":"B"])
        guard let second=server.accept(),server.welcome(second) != nil else { preconditionFailure("no second handshake") }
        precondition(details(server.card(second)) == "B")
        client.stop()
    }

    static func absent() {
        let client=DiscordIPC(paths:["/tmp/ow2-no-such-discord-\(getpid())/discord-ipc-0"],spacing:0.1,retry:0.2)
        client.set(["details":"A"])
        Thread.sleep(forTimeInterval:0.5)
        precondition(!client.connected)
        for n in 0..<20 { client.set(["details":"\(n)"]) }
        let looked=client.attempts
        Thread.sleep(forTimeInterval:1.1)
        precondition(client.attempts-looked <= 7,"\(client.attempts-looked) looks in 1.1 s with a 0.2 s wait")
        client.stop()
    }

    static func rate() {
        let server=FakeDiscord()
        let client=DiscordIPC(applicationID:"1234",paths:[server.path],spacing:0.05,burst:3,window:1.5,retry:0.3)
        client.set(["details":"0"])
        guard let fd=server.accept(),server.welcome(fd) != nil,server.card(fd) != nil else { preconditionFailure("no handshake") }
        let start=Date()
        for n in 1...3 { client.set(["details":"\(n)"]);Thread.sleep(forTimeInterval:0.15) }
        precondition(details(server.card(fd)) == "1" && details(server.card(fd)) == "2" && Date().timeIntervalSince(start) < 1.0)
        precondition(details(server.card(fd,3000)) == "3" && Date().timeIntervalSince(start) > 1.2,"the fourth update in a window waits for it")
        client.stop()
    }

    static func refusals() {
        let server=FakeDiscord()
        let ipc=DiscordIPC(applicationID:"1234",paths:[server.path],spacing:0.05,burst:100,retry:0.3)
        let card:[String:Any]=["type":0,"details":"In Menus","timestamps":["start":1],"assets":["small_image":"https://x/b.png"],
                               "buttons":[["label":"Get Recall","url":"https://github.com/x"]]]
        ipc.set(card)
        guard let fd=server.accept(),server.welcome(fd) != nil,let first=server.frame(fd) else { preconditionFailure("no card") }
        precondition(((first.json["args"] as? [String:Any])?["activity"] as? [String:Any])?["buttons"] != nil)
        func refuse(_ message:[String:Any]) {
            server.send(fd,DiscordFrame.frame,["cmd":"SET_ACTIVITY","evt":"ERROR","nonce":message["nonce"] ?? "","data":["code":4000,"message":"bad"]])
        }
        refuse(first.json)
        guard let second=server.frame(fd),let lean=(second.json["args"] as? [String:Any])?["activity"] as? [String:Any] else { preconditionFailure("no leaner card") }
        precondition(lean["buttons"] == nil && lean["assets"] == nil && lean["details"] as? String == "In Menus","\(lean)")
        refuse(second.json)
        guard let third=server.frame(fd),let bare=(third.json["args"] as? [String:Any])?["activity"] as? [String:Any] else { preconditionFailure("no bare card") }
        precondition(Set(bare.keys) == ["type","timestamps"] && ipc.lastAnswer == "refused_4000","\(bare) \(String(describing:ipc.lastAnswer))")
        refuse(third.json)
        precondition(server.frame(fd,600) == nil,"no fourth try")
        server.send(fd,DiscordFrame.close,["code":4000,"message":"Invalid Client ID"])
        precondition(server.closed(fd) && server.accept(800) == nil && ipc.lastAnswer == "closed_4000")
        ipc.stop()
        precondition(ipc.lastAnswer == "closed_4000","the answer outlives stop()")
    }
}
