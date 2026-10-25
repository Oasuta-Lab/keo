import Foundation

/// Les dates humaines ne se voient qu'à l'œil, et l'arithmétique des années est exactement ce
/// qui se trompe en silence au passage d'un 1er janvier.
func checkHumanDates() {
    let calendar = Calendar(identifier: .gregorian)
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var parts = DateComponents(year: y, month: m, day: d, hour: 12)
        parts.timeZone = TimeZone(identifier: "Europe/Paris")
        return Calendar.current.date(from: parts)!
    }

    let now = day(2026, 10, 25)

    // --- l'écart en années --------------------------------------------------------------
    assert(HumanDate.yearsAgo(from: day(2026, 1, 2), to: now, calendar: calendar) == "Cette année",
           "même année civile, même si dix mois séparent les deux")
    assert(HumanDate.yearsAgo(from: day(2025, 12, 31), to: now, calendar: calendar)
           == "L'année dernière",
           "la veille du Nouvel An est l'année dernière, pas « il y a un an »")
    assert(HumanDate.yearsAgo(from: day(2019, 7, 9), to: now, calendar: calendar)
           == "Il y a sept ans", HumanDate.yearsAgo(from: day(2019, 7, 9), to: now, calendar: calendar))
    assert(HumanDate.yearsAgo(from: day(2009, 7, 14), to: now, calendar: calendar)
           == "Il y a dix-sept ans" || HumanDate.yearsAgo(from: day(2009, 7, 14), to: now,
                                                          calendar: calendar) == "Il y a 17 ans",
           "au-delà de douze on passe aux chiffres")
    // Une photo datée de demain ne doit pas dire « il y a moins zéro an ».
    assert(HumanDate.yearsAgo(from: day(2027, 1, 1), to: now, calendar: calendar) == "Cette année",
           "une date future ne produit pas d'absurdité")

    // --- la phrase ----------------------------------------------------------------------
    let french = Locale(identifier: "fr_FR")
    let story = HumanDate.story(day(2019, 7, 9), locale: french, calendar: calendar)
    assert(story == "Un mardi de juillet 2019", story)

    let origin = HumanDate.origin(day(2009, 7, 14), now: now, locale: french, calendar: calendar)
    assert(origin.hasPrefix("Juillet 2009 — il y a"), origin)

    print("ok — dates humaines : écart en années, bascule du 1er janvier, futur, et la phrase")
}

/// Une date lue dans le nom du fichier est une autre vérité que la date de prise de vue :
/// elle ne doit jamais s'y mélanger, et pour l'instant seul le banc de mesure la consomme.
/// Ici on épingle les formats réels — et surtout ce qui ne doit PAS passer pour une date.
func checkFilenameDates() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!

    // Le banc tourne « maintenant » ; les tests, eux, doivent donner le même verdict dans
    // dix ans, donc l'horloge est posée.
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!

    func found(_ name: String) -> DateComponents? {
        FilenameDate.capture(from: name, now: now).map {
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: $0)
        }
    }
    func stamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> DateComponents {
        DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    // --- les formats réels -----------------------------------------------------------------
    assert(found("IMG_20190714_103000.jpg") == stamp(2019, 7, 14, 10, 30, 0),
           "le format Android date_heure — \(String(describing: found("IMG_20190714_103000.jpg")))")
    assert(found("VID_20190714_103000.mp4") == stamp(2019, 7, 14, 10, 30, 0))
    assert(found("20190714103000.jpg") == stamp(2019, 7, 14, 10, 30, 0),
           "date et heure collées, sans séparateur")
    assert(found("IMG-20210302-WA0001.jpg") == stamp(2021, 3, 2, 12, 0, 0),
           "WhatsApp : date seule, posée à midi pour ne pas changer de jour avec le fuseau")
    assert(found("Screenshot_2021-03-02-10-20-30.png") == stamp(2021, 3, 2, 10, 20, 30))
    assert(found("Capture d'écran 2021-03-02 à 10.20.30.png") == stamp(2021, 3, 2, 10, 20, 30),
           "le « à » des captures macOS — "
           + "\(String(describing: found("Capture d'écran 2021-03-02 à 10.20.30.png")))")
    assert(found("PXL_20210302_102030123.jpg") == stamp(2021, 3, 2, 12, 0, 0),
           "les millisecondes de Pixel collent un chiffre à l'heure : la date suffit, à midi")

    // --- ce qui ne doit pas passer pour une date --------------------------------------------
    assert(found("IMG_4821.HEIC") == nil, "un compteur d'iPhone n'est pas une date")
    assert(found("P1090715.JPG") == nil, "un compteur Panasonic non plus — sept chiffres")
    assert(found("20771231_120000.jpg") == nil, "un nom qui ment (futur lointain) est rejeté")
    assert(found("19891231.jpg") == nil, "avant 1990 : déchet d'outil, pas une prise de vue")
    assert(found("20190230_101010.jpg") == nil, "le 30 février n'existe pas")
    assert(found("2021-0302.jpg") == nil, "un séparateur qui ne se répète pas n'est pas une date")
    assert(found("0612345678.jpg") == nil, "un numéro de téléphone n'a pas la tête d'une date")
    assert(found("Facture 202103029876543.pdf") == nil,
           "huit chiffres au milieu d'une référence ne font pas une date")

    print("ok — dates de nom de fichier : Android, WhatsApp, captures d'écran, Pixel, "
        + "et les pièges — compteurs, futur, 30 février, références")
}
