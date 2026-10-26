import Foundation

/// `Content-Range` parsing is what keeps AVFoundation from believing a multi-gigabyte video is
/// the size of one fetched window. A wrong answer here is a video that stops after four
/// megabytes or never starts — a black screen, not a crash, so no check would catch it later.
func checkVideoRange() {
    func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://mafreebox.freebox.fr/v")!,
                        statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    assert(AuthenticatedAsset.totalLength(response(206, ["Content-Range": "bytes 0-1/12345"])) == 12_345,
           "la taille du fichier est après la barre, pas la taille de la fenêtre servie")
    assert(AuthenticatedAsset.totalLength(response(206, ["Content-Range": "bytes 0-1/5000000000"])) == 5_000_000_000,
           "un clip GoPro dépasse 32 bits : la taille doit rester exacte")
    assert(AuthenticatedAsset.totalLength(response(206, ["Content-Range": "bytes 0-1/*"])) == nil,
           "une taille annoncée inconnue (*) se dit inconnue, pas « deux octets »")
    assert(AuthenticatedAsset.totalLength(response(206, ["Content-Length": "2"])) == nil,
           "une réponse partielle sans Content-Range ne doit pas faire passer la fenêtre pour le fichier")
    assert(AuthenticatedAsset.totalLength(response(200, ["Content-Length": "42"])) == 42,
           "sur une réponse entière, Content-Length dit bien la taille du fichier")

    print("ok — vidéo : la taille du fichier vient de Content-Range, jamais de la fenêtre")
}
