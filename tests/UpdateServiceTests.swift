import Foundation

// Update check parsing and, with arguments, a real install: the app at argument 1
// (a Developer ID copy standing in for the installed app, on a scratch volume) is
// replaced from the disk image at argument 2, which must hold a newer notarized
// build of the same app (version in argument 3). Never point it at /Applications.
@main struct UpdateServiceTests {
    static let notes="## What's new\n\n- **Faster.** Frames take less work.\n- See [the notes](https://example.com).\n\n## Install\n\n- Drag the app.\n"
    static func release(_ tag:String, assets:[[String:Any]], draft:Bool=false, prerelease:Bool=false, body:String=notes) -> Data {
        try! JSONSerialization.data(withJSONObject:["tag_name":tag,"draft":draft,"prerelease":prerelease,
            "html_url":"https://github.com/AsherJN/recall/releases/tag/\(tag)",
            "body":body,"assets":assets])
    }
    static func disk(_ version:String, digest:String?="sha256:"+String(repeating:"a",count:64), name:String="Recall") -> [String:Any] {
        var asset:[String:Any]=["name":"\(name)-\(version).dmg","size":242_000_000,
            "browser_download_url":"https://github.com/AsherJN/recall/releases/download/v\(version)/\(name)-\(version).dmg"]
        if let digest { asset["digest"]=digest }
        return asset
    }
    @MainActor static func main() async throws {
        precondition(UpdateCheck.isNewer("1.0.1",than:"1.0.0") && UpdateCheck.isNewer("1.1",than:"1.0.9") && UpdateCheck.isNewer("2.0.0",than:"1.10.3"))
        precondition(!UpdateCheck.isNewer("1.0.0",than:"1.0.0") && !UpdateCheck.isNewer("1.0",than:"1.0.0") && !UpdateCheck.isNewer("0.1.6",than:"1.0.0"))
        precondition(!UpdateCheck.isNewer("1.0.1-beta",than:"1.0.0") && !UpdateCheck.isNewer("",than:"1.0.0") && !UpdateCheck.isNewer("1..2",than:"1.0"))
        let found=try UpdateCheck.parse(release("v1.0.1",assets:[disk("1.0.1")]),current:"1.0.0")
        precondition(found?.version == "1.0.1" && found?.sha256 == String(repeating:"a",count:64) && found?.size == 242_000_000)
        precondition(found?.notes == ["Faster. Frames take less work.","See the notes."],"\(found?.notes ?? [])")
        let same=try UpdateCheck.parse(release("v1.0.0",assets:[disk("1.0.0")]),current:"1.0.0")
        let draft=try UpdateCheck.parse(release("v1.0.1",assets:[disk("1.0.1")],draft:true),current:"1.0.0")
        let prerelease=try UpdateCheck.parse(release("v1.0.1",assets:[disk("1.0.1")],prerelease:true),current:"1.0.0")
        precondition(same == nil && draft == nil && prerelease == nil)
        for broken in [release("v1.0.1",assets:[]),release("v1.0.1",assets:[disk("1.0.2")]),release("v1.0.1",assets:[disk("1.0.1",digest:nil)]),
                       release("v1.0.1",assets:[disk("1.0.1",digest:"sha256:short")])] {
            do { _ = try UpdateCheck.parse(broken,current:"1.0.0");fatalError("Accepted an unusable release") }
            catch let e as SetupFailure { precondition(e.code == "update_unavailable") }
        }
        var insecure=disk("1.0.1");insecure["browser_download_url"]="http://github.com/x.dmg"
        do { _ = try UpdateCheck.parse(release("v1.0.1",assets:[insecure]),current:"1.0.0");fatalError("Accepted plain HTTP") }
        catch let e as SetupFailure { precondition(e.code == "update_unavailable") }
        let checksumOnly=disk("1.0.1",digest:nil)
        let withChecksum=try UpdateCheck.parse(release("v1.0.1",assets:[checksumOnly,["name":"Recall-1.0.1.dmg.sha256","browser_download_url":"https://github.com/c.sha256"]]),current:"1.0.0")
        precondition(withChecksum?.sha256 == "" && withChecksum?.checksum != nil)
        // After a rename the one "<name>-<version>.dmg" is used; this app's own
        // name wins when several exist; two foreign names are ambiguous.
        let renamed=try UpdateCheck.parse(release("v1.0.1",assets:[disk("1.0.1",name:"NewName")]),current:"1.0.0")
        precondition(renamed?.download.lastPathComponent == "NewName-1.0.1.dmg")
        let preferred=try UpdateCheck.parse(release("v1.0.1",assets:[disk("1.0.1",name:"Other"),disk("1.0.1")]),current:"1.0.0")
        precondition(preferred?.download.lastPathComponent == "Recall-1.0.1.dmg")
        do { _ = try UpdateCheck.parse(release("v1.0.1",assets:[disk("1.0.1",name:"A"),disk("1.0.1",name:"B")]),current:"1.0.0");fatalError("Picked an ambiguous image") }
        catch let e as SetupFailure { precondition(e.code == "update_unavailable") }
        let renamedChecksum=try UpdateCheck.parse(release("v1.0.1",assets:[disk("1.0.1",digest:nil,name:"NewName"),["name":"NewName-1.0.1.dmg.sha256","browser_download_url":"https://github.com/n.sha256"]]),current:"1.0.0")
        precondition(renamedChecksum?.checksum?.absoluteString == "https://github.com/n.sha256")
        do { _ = try UpdateCheck.parse(Data("not json".utf8),current:"1.0.0");fatalError("Accepted invalid JSON") }
        catch let e as SetupFailure { precondition(e.code == "update_check_failed") }
        // A release states the macOS it needs in a hidden line; without one it needed macOS 26 (1.0).
        precondition(UpdateCheck.minimumMacOS(notes) == "26.0")
        precondition(UpdateCheck.minimumMacOS(notes+"\n<!-- minimum-macos: 15.0 -->\n") == "15.0")
        precondition(UpdateCheck.minimumMacOS("<!--minimum-macos:15-->") == "15")
        precondition(UpdateCheck.minimumMacOS("minimum-macos: 15.0") == "26.0")
        precondition(UpdateCheck.runs("15.0",on:"15.6.1") && UpdateCheck.runs("26.0",on:"26.0.0") && UpdateCheck.runs("15",on:"26.1"))
        precondition(!UpdateCheck.runs("26.0",on:"15.7.1") && !UpdateCheck.runs("15.4",on:"15.3") && !UpdateCheck.runs("latest",on:"26.0"))
        let marked=notes+"\n<!-- minimum-macos: 15.0 -->\n", needsTahoe=notes+"\n<!-- minimum-macos: 26.0 -->\n"
        let unmarkedOnSequoia=try UpdateCheck.parse(release("v1.1.0",assets:[disk("1.1.0")]),current:"1.0.0",system:"15.6.1")
        let tahoeOnlyOnSequoia=try UpdateCheck.parse(release("v1.1.0",assets:[disk("1.1.0")],body:needsTahoe),current:"1.0.0",system:"15.6.1")
        let markedOnSequoia=try UpdateCheck.parse(release("v1.1.0",assets:[disk("1.1.0")],body:marked),current:"1.0.0",system:"15.6.1")
        let unmarkedOnTahoe=try UpdateCheck.parse(release("v1.1.0",assets:[disk("1.1.0")]),current:"1.0.0",system:"26.6.2")
        let markedOnTahoe=try UpdateCheck.parse(release("v1.1.0",assets:[disk("1.1.0")],body:marked),current:"1.0.0",system:"26.6.2")
        precondition(unmarkedOnSequoia == nil && tahoeOnlyOnSequoia == nil && markedOnSequoia?.version == "1.1.0")
        precondition(unmarkedOnTahoe?.version == "1.1.0" && markedOnTahoe?.notes.count == 2)
        // From 1.2 a release needs macOS 26.5 (Overwatch hangs under older Rosetta): offered on 26.5 and later only.
        let needs265=notes+"\n<!-- minimum-macos: 26.5 -->\n"
        precondition(UpdateCheck.minimumMacOS(needs265) == "26.5")
        for (system,offered) in [("15.8.1",false),("26.4.1",false),("26.5",true),("26.6.2",true),("27.0",true)] {
            let update=try UpdateCheck.parse(release("v1.2.0",assets:[disk("1.2.0")],body:needs265),current:"1.1.0",system:system)
            precondition((update?.version == "1.2.0") == offered,"1.2.0 on macOS \(system)")
        }
        print("PASS: version order, release parsing, drafts/pre-releases, unusable and insecure assets, renamed images, notes, minimum macOS")

        let args=CommandLine.arguments
        guard args.count == 4 else { return }
        let installed=URL(fileURLWithPath:args[1]),image=URL(fileURLWithPath:args[2]),version=args[3]
        precondition(!installed.path.hasPrefix("/Applications"),"Use a scratch copy")
        guard let team=UpdateInstaller.team(of:installed) else { fatalError("The stand-in app has no Developer ID signature") }
        let identifier=NSDictionary(contentsOf:installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as! String
        let digest=try UpdateInstaller.sha256(of:image)
        let size=(try FileManager.default.attributesOfItem(atPath:image.path)[.size] as! NSNumber).int64Value
        let work=installed.deletingLastPathComponent().appendingPathComponent(".update-work")
        func update(sha:String, version:String=version) -> AvailableUpdate {
            AvailableUpdate(version:version,notes:[],page:URL(string:"https://github.com")!,download:image,size:size,sha256:sha,checksum:nil)
        }
        let executable=installed.appendingPathComponent("Contents/MacOS/"+(NSDictionary(contentsOf:installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleExecutable"] as! String))
        let before=try UpdateInstaller.sha256(of:executable)
        // A wrong checksum or a version the image does not hold changes nothing.
        for (candidate,code) in [(update(sha:String(repeating:"0",count:64)),"update_hash_mismatch"),(update(sha:digest,version:"9.9.9"),"update_signature_invalid")] {
            do { try await UpdateInstaller.install(candidate,over:installed,team:team,identifier:identifier,work:work) { _ in };fatalError("Installed a bad update") }
            catch let e as SetupFailure { precondition(e.code == code,"\(e.code)") }
            let after=try UpdateInstaller.sha256(of:executable)
            precondition(after == before)
        }
        // Another team's signature is refused.
        do { try await UpdateInstaller.install(update(sha:digest),over:installed,team:"AAAAAAAAAA",identifier:identifier,work:work) { _ in };fatalError("Accepted another team") }
        catch let e as SetupFailure { precondition(e.code == "update_signature_invalid") }
        final class Reports: @unchecked Sendable { var count=0 }
        let reports=Reports()
        try await UpdateInstaller.install(update(sha:digest),over:installed,team:team,identifier:identifier,work:work) { _ in reports.count+=1 }
        let info=NSDictionary(contentsOf:installed.appendingPathComponent("Contents/Info.plist"))
        precondition(info?["CFBundleShortVersionString"] as? String == version)
        try UpdateInstaller.verify(installed,team:team,identifier:identifier,version:version)
        // An app that needs a newer macOS than this Mac has is refused before anything is replaced.
        if let minimum=info?["LSMinimumSystemVersion"] as? String,let major=UpdateCheck.parts(minimum)?.first,major>1 {
            do { try UpdateInstaller.verify(installed,team:team,identifier:identifier,version:version,system:"\(major-1).0");fatalError("Accepted an app for a newer macOS") }
            catch let e as SetupFailure { precondition(e.code == "update_needs_newer_macos") }
        }
        let leftovers=try FileManager.default.contentsOfDirectory(atPath:installed.deletingLastPathComponent().path).filter { $0.hasPrefix(".") && $0 != ".DS_Store" }
        precondition(leftovers.isEmpty,"Left behind: \(leftovers)")
        print("PASS: real install from a notarized image; bad checksum, wrong version, other teams and newer macOS change nothing; \(reports.count) progress reports")
    }
}
