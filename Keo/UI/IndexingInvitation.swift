import SwiftUI

/// Shown once, when the index is empty.
///
/// Without it the app looks broken rather than unconfigured: the timeline shows one block and
/// the date sort does nothing, because the only dates the NAS gives are the day everything was
/// copied. Nothing on screen explains why, or that one pass fixes it for good.
struct IndexingInvitation: View {
    let client: FreeboxClient
    let start: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CageMark.Filled(height: 84)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    Text("Tes photos n'ont pas encore de date")
                        .font(.title2.bold())

                    Text("Le NAS ne connaît que la date à laquelle un fichier y a été copié. "
                       + "Si ta photothèque est arrivée en bloc, toutes tes photos portent la "
                       + "même date — le tri par date et la timeline ne servent alors à rien.\n\n"
                       + "Keo peut parcourir ta bibliothèque une fois pour en construire son "
                       + "propre index.")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 14) {
                        point("photo.badge.checkmark",
                              "La vraie date de prise de vue est dans la photo elle-même. "
                            + "Keo n'en lit que les premiers kilo-octets pour la récupérer, "
                            + "jamais le fichier entier.")
                        point("clock.arrow.circlepath",
                              "C'est long une fois, puis plus jamais : une photo déjà lue n'est "
                            + "jamais relue, et ajouter des photos ne coûte que les nouvelles.")
                        point("square.stack.3d.up",
                              "L'index retient aussi la structure de tes dossiers et leurs "
                            + "totaux : c'est lui qui les ouvre instantanément et affiche ce "
                            + "qu'ils contiennent.")
                        point("arrow.triangle.2.circlepath",
                              "Ça continue pendant que tu navigues, se met en pause quand tu "
                            + "quittes l'app, et reprend là où ça s'était arrêté.")
                    }

                    Text("Tu peux parcourir tes dossiers sans rien lancer — seules les "
                       + "fonctions liées aux dates resteront en sommeil.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        start()
                        dismiss()
                    } label: {
                        Text("Lancer l'indexation")
                            .frame(maxWidth: .infinity)
                    }
                    // The label colour SwiftUI picks for a prominent button assumes a
                    // dark fill. Keo's accent is a pale peach in both appearances, where white
                    // on it falls to 2.1:1 — `OnAccent` flips with the appearance.
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color("OnAccent"))
                    .controlSize(.large)

                    Button("Plus tard") { dismiss() }
                        .font(.subheadline)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
