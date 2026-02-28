import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voxt")
                        .font(.headline)
                    Text("On-device push-to-talk transcription powered by MLX Audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        HStack(spacing: 4) {
                            Text("Version")
                            Text(version)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("License")
                        .font(.headline)
                    Text("MIT License")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project")
                        .font(.headline)
                    Link("github.com/hehehai/voxt", destination: URL(string: "https://github.com/hehehai/voxt")!)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Author")
                        .font(.headline)
                    Link("hehehai", destination: URL(string: "https://www.hehehai.cn/")!)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Thanks")
                        .font(.headline)
                    Link(
                        "github.com/Blaizzy/mlx-audio-swift",
                        destination: URL(string: "https://github.com/Blaizzy/mlx-audio-swift")!
                    )
                    .font(.caption)
                    Link(
                        "github.com/fayazara/Kaze",
                        destination: URL(string: "https://github.com/fayazara/Kaze")!
                    )
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }
}
