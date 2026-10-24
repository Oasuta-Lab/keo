import Foundation

// MARK: - Date de prise de vue des vidéos
//
// Fixtures ISO-BMFF fabriquées octet par octet : déterministes, sans fichier de référence,
// et capables de décrire un mdat d'un mégaoctet sans jamais le matérialiser (le scanner ne
// voit que des tranches). La règle d'or vérifiée partout : des octets manquants donnent
// `.need`, jamais `.absent` — un échec de lecture ne doit jamais devenir « pas de date ».

private func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
private func be32(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
}
private func be64(_ v: UInt64) -> Data { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

/// MacRoman pour que "©day" produise bien l'octet 0xA9.
private func atom(_ type: String, _ payload: Data) -> Data {
    atom(rawType: type.data(using: .macOSRoman)!, payload)
}

private func atom(rawType: Data, _ payload: Data) -> Data {
    precondition(rawType.count == 4)
    return be32(UInt32(payload.count + 8)) + rawType + payload
}

/// En-tête seul d'un atome déclarant `bodyBytes` octets de contenu jamais fournis.
private func hollow(_ type: String, bodyBytes: Int64, large: Bool = false) -> Data {
    let raw = type.data(using: .macOSRoman)!
    return large ? be32(1) + raw + be64(UInt64(bodyBytes) + 16)
                 : be32(UInt32(bodyBytes) + 8) + raw
}

private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: y, month: mo, day: d,
                                              hour: h, minute: mi, second: s))!
}

private let ftyp = atom("ftyp", "qt  ".data(using: .ascii)! + be32(0) + "qt  ".data(using: .ascii)!)

private func mvhd(creation1904: UInt32) -> Data {
    atom("mvhd", be32(0) + be32(creation1904) + be32(creation1904)
               + be32(600) + be32(0) + Data(count: 80))
}

private func mvhdV1(creation1904: UInt64) -> Data {
    atom("mvhd", be32(0x0100_0000) + be64(creation1904) + be64(creation1904)
               + be32(600) + be64(0) + Data(count: 80))
}

private func dataAtom(_ value: String) -> Data {
    atom("data", be32(1) + be32(0) + value.data(using: .utf8)!)
}

/// moov/meta façon iPhone : clés `mdta`, valeur `com.apple.quicktime.creationdate`.
private func metaCreation(_ stamp: String, isoLayout: Bool) -> Data {
    let key = "com.apple.quicktime.creationdate".data(using: .utf8)!
    let hdlr = atom("hdlr", be32(0) + be32(0) + "mdta".data(using: .ascii)! + Data(count: 12))
    let keys = atom("keys", be32(0) + be32(1)
                          + be32(UInt32(8 + key.count)) + "mdta".data(using: .ascii)! + key)
    let ilst = atom("ilst", atom(rawType: be32(1), dataAtom(stamp)))
    return atom("meta", (isoLayout ? be32(0) : Data()) + hdlr + keys + ilst)
}

private func udtaDay(_ stamp: String) -> Data {
    let text = stamp.data(using: .utf8)!
    return atom("udta", atom("©day", be16(UInt16(text.count)) + be16(0) + text))
}

private func slice(_ data: Data, at offset: Int64 = 0) -> VideoDate.Slice {
    VideoDate.Slice(offset: offset, data: data)
}

func checkVideoDate() async throws {
    let now = utcDate(2026, 10, 24, 12, 0, 0)
    let mac1904: UInt64 = 2_082_844_800

    func verdict(_ slices: [VideoDate.Slice], fileSize: Int64) -> VideoDate.Scan {
        VideoDate.scan(slices, fileSize: fileSize, now: now)
    }

    // L'ordre de préférence : creationdate (avec fuseau) bat mvhd.
    let taken2021 = utcDate(2021, 6, 19, 15, 12, 43) // 17:12:43+0200
    let mvhd2001 = mvhd(creation1904: UInt32(utcDate(2001, 1, 1, 0, 0, 0).timeIntervalSince1970
                                             + Double(mac1904)))
    let fastStart = ftyp + atom("moov", mvhd2001 + metaCreation("2021-06-19T17:12:43+0200",
                                                                isoLayout: false))
                         + atom("mdat", Data(count: 32))
    assert(verdict([slice(fastStart)], fileSize: Int64(fastStart.count)) == .found(taken2021),
           "creationdate (fuseau inclus) doit gagner sur mvhd")

    // La variante ISO de meta (version/flags avant hdlr) doit donner la même chose.
    let isoMeta = ftyp + atom("moov", metaCreation("2021-06-19T15:12:43Z", isoLayout: true))
    assert(verdict([slice(isoMeta)], fileSize: Int64(isoMeta.count)) == .found(taken2021),
           "meta en FullBox ISO doit être compris aussi")

    // LE point crucial : un préfixe trop court donne `.need`, jamais un verdict.
    guard case .need = verdict([slice(fastStart.prefix(24))], fileSize: Int64(fastStart.count))
    else { assertionFailure("tronqué au milieu du moov : on ne conclut pas"); return }

    // moov en fin de fichier derrière un mdat d'un méga-octet jamais matérialisé :
    // le scanner saute l'en-tête et réclame exactement la plage du moov.
    let moovTail = atom("moov", metaCreation("2019-02-03T08:09:10Z", isoLayout: false))
    let bigBody: Int64 = 1_000_000
    for large in [false, true] { // tailles 32 et 64 bits
        let head = ftyp + hollow("mdat", bodyBytes: bigBody, large: large)
        let moovAt = Int64(head.count) + bigBody
        let total = moovAt + Int64(moovTail.count)
        guard case .need(let asked) = verdict([slice(head)], fileSize: total) else {
            assertionFailure("moov en fin (large=\(large)) : il faut demander la suite"); return
        }
        assert(asked.lowerBound == moovAt,
               "le saut doit viser l'offset exact du moov — \(asked) vs \(moovAt)")
        assert(verdict([slice(head), slice(moovTail, at: moovAt)], fileSize: total)
               == .found(utcDate(2019, 2, 3, 8, 9, 10)),
               "deux tranches suffisent, le mdat n'est jamais lu (large=\(large))")
    }

    // mdat de taille 0 (« jusqu'à la fin ») sans moov : verdict sûr, et pas de boucle.
    let endless = ftyp + be32(0) + "mdat".data(using: .ascii)!
    assert(verdict([slice(endless)], fileSize: Int64(endless.count) + 500) == .absent,
           "size==0 va jusqu'à la fin : pas de moov, pas de date, pas de boucle")

    // mvhd seul : plausible → trouvé ; zéro → absent ; futur → absent.
    let shot2010 = utcDate(2010, 5, 4, 10, 0, 0)
    let only = ftyp + atom("moov", mvhd(creation1904: UInt32(shot2010.timeIntervalSince1970
                                                             + Double(mac1904))))
    assert(verdict([slice(only)], fileSize: Int64(only.count)) == .found(shot2010),
           "mvhd en dernier recours")
    let zero = ftyp + atom("moov", mvhd(creation1904: 0))
    assert(verdict([slice(zero)], fileSize: Int64(zero.count)) == .absent,
           "creation_time = 0 est du bruit, pas une date")
    let future = ftyp + atom("moov", mvhdV1(creation1904:
        UInt64(utcDate(2090, 1, 1, 0, 0, 0).timeIntervalSince1970) + mac1904))
    assert(verdict([slice(future)], fileSize: Int64(future.count)) == .absent,
           "une date future est rejetée (et mvhd v1 64 bits est lu)")

    // Bogue d'écrivain connu : un temps Unix rangé dans un champ à époque 1904.
    let shot2015 = utcDate(2015, 3, 3, 9, 30, 0)
    let buggy = ftyp + atom("moov", mvhd(creation1904: UInt32(shot2015.timeIntervalSince1970)))
    assert(verdict([slice(buggy)], fileSize: Int64(buggy.count)) == .found(shot2015),
           "un mvhd écrit en époque Unix est récupéré, pas daté de 1958")

    // ©day classique dans udta ; une année nue ne compte pas comme prise de vue.
    let day = ftyp + atom("moov", udtaDay("2003-08-12T09:30:00Z"))
    assert(verdict([slice(day)], fileSize: Int64(day.count))
           == .found(utcDate(2003, 8, 12, 9, 30, 0)), "©day de QuickTime classique")
    let bareYear = ftyp + atom("moov", udtaDay("2003"))
    assert(verdict([slice(bareYear)], fileSize: Int64(bareYear.count)) == .absent,
           "une année nue n'est pas une date de prise de vue")

    // Pas un ISO-BMFF (AVI, MKV…) : verdict sûr immédiat, inutile d'insister.
    let avi = "RIFF\u{04}\u{00}\u{00}\u{00}AVI LIST".data(using: .macOSRoman)!
    assert(verdict([slice(avi)], fileSize: 5_000_000) == .absent,
           "un conteneur étranger est tranché sans autre requête")

    // Corruption : taille d'atome < 8 ou débordant le parent — terminer, sans planter.
    let corrupt = ftyp + be32(7) + "zzzz".data(using: .ascii)! + Data(count: 64)
    assert(verdict([slice(corrupt)], fileSize: Int64(corrupt.count)) == .absent,
           "une taille aberrante arrête le parcours proprement")
    let overflow = ftyp + atom("moov", be32(0xFFFF_FFF0) + "udta".data(using: .ascii)!
                                     + mvhd(creation1904: UInt32(shot2010.timeIntervalSince1970
                                                                 + Double(mac1904))))
    assert(verdict([slice(overflow)], fileSize: Int64(overflow.count)) == .absent,
           "un enfant qui déborde son parent ne fait ni boucle ni faux positif")

    // Le pilote : moov en fin résolu en exactement deux requêtes, plages dans le fichier.
    let real = ftyp + atom("mdat", Data(count: 150_000))
                    + atom("moov", metaCreation("2022-12-25T10:11:12Z", isoLayout: false))
    let realSize = Int64(real.count)
    var asked: [Range<Int64>] = []
    let found = try await VideoDate.capture(fileSize: realSize, now: now) { range in
        asked.append(range)
        assert(range.lowerBound >= 0 && range.upperBound <= realSize,
               "jamais de plage hors du fichier — \(range)")
        let low = real.startIndex + Int(range.lowerBound)
        return real[low ..< low + Int(range.upperBound - range.lowerBound)]
    }
    assert(found == utcDate(2022, 12, 25, 10, 11, 12), "le pilote aboutit")
    assert(asked.count == 2, "préfixe puis moov : deux requêtes, pas plus — \(asked)")

    // Un serveur qui répond court n'autorise aucun verdict : on jette, on ne range rien.
    do {
        _ = try await VideoDate.capture(fileSize: realSize, now: now) { _ in Data() }
        assertionFailure("une plage non honorée doit lever Undecided")
    } catch is VideoDate.Undecided {}

    print("ok — dates vidéo : préférences, moov en fin, 64 bits, troncature => need, "
          + "corruption, pilote en deux requêtes")
}
