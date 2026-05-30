import SwiftUI

struct RadioMark: View {
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(isSelected ? Color.logosAmber : Color.clear)
            .frame(width: 18, height: 18)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                } else {
                    Circle().stroke(Color.logosLabel4, lineWidth: 1.5)
                }
            }
    }
}

struct BreathingDot: View {
    let color: Color
    let isActive: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .scaleEffect(isActive && pulse ? 1.35 : 1)
            .opacity(isActive && pulse ? 0.55 : 1)
            .onAppear { updatePulse() }
            .onChange(of: isActive) { _, _ in updatePulse() }
    }

    private func updatePulse() {
        if isActive {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            pulse = false
        }
    }
}

struct ChatBubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let topLeft: CGFloat = 20
        let topRight: CGFloat = 20
        let bottomLeft: CGFloat = isUser ? 20 : 6
        let bottomRight: CGFloat = isUser ? 6 : 20

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + topRight), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topLeft, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct LiquidGlassScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder
    func liquidGlassPill(
        tint: Color = Color.white.opacity(0.07),
        isRecording: Bool = false,
        isFocused: Bool = false,
        isInteractive: Bool = false
    ) -> some View {
        if isRecording {
            self
                .background(Color.logosRed, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
                }
                .shadow(color: Color.logosRed.opacity(0.45), radius: 24, x: 0, y: 0)
                .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 8)
        } else {
            self
                .background(tint, in: Capsule())
                .glassEffect(.regular.tint(tint).interactive(isInteractive), in: Capsule())
                .liquidGlassPillChrome(isFocused: isFocused)
        }
    }

    func liquidGlassPillChrome(isFocused: Bool) -> some View {
        self
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.14), location: 0),
                        .init(color: Color.white.opacity(0), location: 0.38),
                        .init(color: Color.white.opacity(0), location: 0.68),
                        .init(color: Color.white.opacity(0.08), location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(Capsule())
                .blendMode(.screen)
                .allowsHitTesting(false)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.52),
                                Color.white.opacity(0.24),
                                Color.black.opacity(0.17)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    )
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        isFocused ? Color.logosAmber.opacity(0.55) : Color.white.opacity(0.24),
                        lineWidth: isFocused ? 1.5 : 0.5
                    )
            }
            .shadow(color: Color.black.opacity(0.67), radius: 28, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 2)
    }
}

struct AmberPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.logosAmberOn)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(Color.logosAmber.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
    }
}

struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.logosLabel)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(Color.clear, in: Capsule())
            .overlay(Capsule().stroke(Color.logosHairline, lineWidth: 0.7))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct AmberChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.logosAmberOn)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.logosAmber.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
    }
}

struct GreenChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.logosAmberOn)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.logosGreen.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
    }
}

struct RedChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.logosRed)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.logosRed.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(Color.logosRed.opacity(0.35), lineWidth: 0.7))
    }
}

struct NeutralChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.logosLabel)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.logosBG3.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

extension View {
    func settingsGroup() -> some View {
        self
            .background(Color.logosBG2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.logosHairline, lineWidth: 0.5))
    }
}

extension Image {
    func settingsIcon() -> some View {
        self
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.logosLabel2)
            .frame(width: 22, height: 22)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }

    static let logosBG = Color(hex: 0x000000)
    static let logosBG1 = Color(hex: 0x0E0E10)
    static let logosBG2 = Color(hex: 0x1C1C1E)
    static let logosBG3 = Color(hex: 0x2C2C2E)
    static let logosBG4 = Color(hex: 0x3A3A3C)
    static let logosSep = Color(red: 84 / 255, green: 84 / 255, blue: 88 / 255, opacity: 0.65)
    static let logosSepFaint = Color(red: 84 / 255, green: 84 / 255, blue: 88 / 255, opacity: 0.35)
    static let logosHairline = Color.white.opacity(0.08)
    static let logosLabel = Color(hex: 0xFFFFFF)
    static let logosLabel2 = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.60)
    static let logosLabel3 = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.30)
    static let logosLabel4 = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.16)
    static let logosAmber = Color(hex: 0xFFAA33)
    static let logosAmberBright = Color(hex: 0xFFC470)
    static let logosAmberDeep = Color(hex: 0xE8901C)
    static let logosAmberSoft = Color(red: 255 / 255, green: 170 / 255, blue: 51 / 255, opacity: 0.18)
    static let logosAmberSoft2 = Color(red: 255 / 255, green: 170 / 255, blue: 51 / 255, opacity: 0.08)
    static let logosAmberGlow = Color(red: 255 / 255, green: 170 / 255, blue: 51 / 255, opacity: 0.45)
    static let logosAmberOn = Color(hex: 0x1A1306)
    static let logosGreen = Color(hex: 0x30D158)
    static let logosRed = Color(hex: 0xFF453A)
    static let logosYellow = Color(hex: 0xFFD60A)
    static let logosBlue = Color(hex: 0x0A84FF)
    static let logosTeal = Color(hex: 0x64D2FF)
}
