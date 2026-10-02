import AppKit

/// Battle.net's own icon for the button that opens it, read from the player's installed
/// Battle.net.exe rather than bundled: Recall ships no Blizzard artwork. The largest image
/// in the program's first icon group is used; any file that does not parse as expected
/// simply gives no icon.
enum BattleNetIcon {
    static func load(from exe:URL) -> NSImage? {
        guard let data=try? Data(contentsOf:exe,options:.mappedIfSafe) else { return nil }
        return image(fromPE:data)
    }

    static func image(fromPE data:Data) -> NSImage? {
        let bytes=[UInt8](data)
        func u16(_ o:Int) -> Int? { o >= 0 && o+2 <= bytes.count ? Int(bytes[o]) | Int(bytes[o+1])<<8 : nil }
        func u32(_ o:Int) -> Int? {
            guard o >= 0 && o+4 <= bytes.count else { return nil }
            return Int(bytes[o]) | Int(bytes[o+1])<<8 | Int(bytes[o+2])<<16 | Int(bytes[o+3])<<24
        }
        guard u16(0) == 0x5A4D, let pe=u32(0x3C), u32(pe) == 0x4550,
              let sections=u16(pe+6), let optionalSize=u16(pe+20), let magic=u16(pe+24) else { return nil }
        let optional=pe+24
        let directories=optional+(magic == 0x20B ? 112 : 96)
        guard let resourceRVA=u32(directories+16), resourceRVA != 0 else { return nil }
        // Map a relative virtual address to a file offset through the section table.
        let table=optional+optionalSize
        func offset(_ rva:Int) -> Int? {
            for i in 0..<sections {
                let s=table+i*40
                guard let size=u32(s+8), let address=u32(s+12), let raw=u32(s+16), let pointer=u32(s+20) else { return nil }
                if rva >= address && rva < address+max(size,raw) { return pointer+(rva-address) }
            }
            return nil
        }
        guard let root=offset(resourceRVA) else { return nil }
        // Entries of one resource directory level: (id, offset of child, is directory).
        func entries(_ directory:Int) -> [(id:Int, child:Int, isDirectory:Bool)] {
            guard let named=u16(directory+12), let ids=u16(directory+14) else { return [] }
            return (0..<(named+ids)).compactMap { i in
                let e=directory+16+i*8
                guard let name=u32(e), let target=u32(e+4) else { return nil }
                return (name & 0x7FFF_FFFF, target & 0x7FFF_FFFF, target & 0x8000_0000 != 0)
            }
        }
        // Type → name → language → data, taking the first name and language.
        func resource(type:Int, id:Int?) -> Data? {
            guard let typeEntry=entries(root).first(where:{ $0.id == type && $0.isDirectory }) else { return nil }
            let names=entries(root+typeEntry.child)
            guard let nameEntry=(id.map { want in names.first { $0.id == want } } ?? names.first), nameEntry.isDirectory,
                  let language=entries(root+nameEntry.child).first, !language.isDirectory,
                  let rva=u32(root+language.child), let size=u32(root+language.child+4),
                  let start=offset(rva), size > 0, start+size <= bytes.count else { return nil }
            return Data(bytes[start..<start+size])
        }
        // RT_GROUP_ICON (14) lists the images; RT_ICON (3) holds each one.
        guard let group=resource(type:14,id:nil), group.count >= 6 else { return nil }
        let g=[UInt8](group)
        let count=Int(g[4]) | Int(g[5])<<8
        var best:(edge:Int, entry:[UInt8], id:Int)?
        for i in 0..<count {
            let e=6+i*14
            guard e+14 <= g.count else { break }
            let edge=g[e] == 0 ? 256 : Int(g[e])
            if edge > (best?.edge ?? 0) { best=(edge,Array(g[e..<e+12]),Int(g[e+12]) | Int(g[e+13])<<8) }
        }
        guard let chosen=best, let picture=resource(type:3,id:chosen.id) else { return nil }
        if picture.starts(with:[0x89,0x50,0x4E,0x47]) { return NSImage(data:picture) }
        // A bitmap entry: wrap it in a one-image .ico, which NSImage reads.
        var ico=Data([0,0,1,0,1,0])
        ico.append(contentsOf:chosen.entry[0..<8])
        let size=UInt32(picture.count), at=UInt32(22)
        ico.append(contentsOf:withUnsafeBytes(of:size.littleEndian,Array.init))
        ico.append(contentsOf:withUnsafeBytes(of:at.littleEndian,Array.init))
        ico.append(picture)
        return NSImage(data:ico)
    }
}
