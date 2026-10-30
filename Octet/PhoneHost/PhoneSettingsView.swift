import SwiftUI

/// Settings › Phone: on or off, a pairing code for the Octet phone app, and
/// the phones already paired.
struct PhoneSettingsGroup: View {
    @ObservedObject private var center = PhoneHostCenter.shared
    @State private var host: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsGroup(title: "Phone") {
                SettingsRow(
                    title: "Octet on your phone",
                    detail: "Lets the Octet phone app on this network read your agents, send them messages, stop them, answer their permission requests and watch their terminals. A phone can do nothing until you pair it here, and each one can be removed. On Wi-Fi the traffic isn't encrypted; away from home, reach this Mac over Tailscale."
                ) {
                    Toggle("Octet on your phone", isOn: Binding(get: { center.enabled }, set: { center.enabled = $0 }))
                        .labelsHidden().toggleStyle(OctetSwitchStyle())
                }
                if let error = center.error {
                    SettingsDivider()
                    SettingsRow(title: "Not listening", detail: error) { EmptyView() }
                }
            }
            if center.running {
                pair
                paired
            }
        }
    }

    // MARK: Pairing

    private var pair: some View {
        SettingsGroup(title: "Pair a phone") {
            SettingsRow(title: "Pairing code",
                        detail: "In the Octet phone app choose Add connection and scan this, or type the address and code. It works once and expires in 5 minutes.") {
                if center.pairing == nil {
                    OctetButton(title: "Show Code", icon: "qrcode", kind: .primary, compact: true) { center.newPairing() }
                } else {
                    OctetButton(title: "Hide", kind: .secondary, compact: true) { center.cancelPairing() }
                }
            }
            if let pairing = center.pairing {
                SettingsDivider()
                let addresses = center.addresses
                let chosen = host ?? addresses.first?.host
                HStack(alignment: .top, spacing: 20) {
                    if let chosen, let link = center.pairingLink(host: chosen), let image = PhoneHostCenter.qrImage(link) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .padding(8)
                            .background(Color.white)
                            .accessibilityLabel("Pairing QR code")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if let chosen {
                            line("Address", "\(chosen):\(center.port.map(String.init) ?? "")")
                        }
                        line("Code", pairing.credential)
                        if addresses.count > 1 {
                            Picker("Reach this Mac over", selection: Binding(get: { chosen ?? "" }, set: { host = $0 })) {
                                ForEach(addresses) { Text("\($0.label) · \($0.host)").tag($0.host) }
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 220)
                        }
                        if addresses.isEmpty {
                            Text("This Mac has no network address a phone could reach.")
                                .font(Theme.interfaceFont(11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.interfaceFont(11.5)).foregroundStyle(Theme.textTertiary).frame(width: 52, alignment: .leading)
            OctetCopyText(text: value, help: "Copy \(title.lowercased())")
        }
    }

    // MARK: Paired phones

    private var paired: some View {
        SettingsGroup(title: "Paired phones") {
            if center.phones.isEmpty {
                SettingsRow(title: "No phones paired", detail: "Show a pairing code above to add one.") { EmptyView() }
            }
            ForEach(Array(center.phones.enumerated()), id: \.element.id) { index, phone in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: phone.label, detail: "\(phone.os.map { "\($0) · " } ?? "")Paired \(phone.issuedAt.formatted(date: .abbreviated, time: .omitted))") {
                    OctetButton(title: "Remove", kind: .destructive, compact: true) { center.revoke(phone) }
                }
            }
            if center.phones.count > 1 {
                SettingsDivider()
                SettingsRow(title: "Remove all phones", detail: "Every paired phone is signed out at once.") {
                    OctetButton(title: "Remove All", kind: .destructive, compact: true) { center.revokeAll() }
                }
            }
        }
    }
}
