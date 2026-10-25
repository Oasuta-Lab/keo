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
