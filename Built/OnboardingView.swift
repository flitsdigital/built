import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @State private var step = 0
    @State private var name = ""
    @State private var age = 22
    @State private var height = 176
    @State private var weight = 70.0
    @State private var goalWeight = 78.0
    @State private var goalDate = Calendar.current.date(byAdding: .month, value: 12, to: .now) ?? .now
    @State private var trainings = 3
    @State private var showNameHint = false
    @State private var started = false
    @FocusState private var nameFocused: Bool

    private var weeks: Double { max(goalDate.timeIntervalSinceNow / 604_800, 1) }
    private var rate: Double { (goalWeight - weight) / weeks }
    private var proteinTarget: Int { Int((goalWeight * 1.6).rounded()) }

    var body: some View {
        TabView(selection: $step) {
            stepAboutYou.tag(0)
            stepGoal.tag(1)
            stepPlan.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Color(.systemBackground))
        .animation(.snappy(duration: 0.3), value: step)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 32)
    }

    private func nextButton(_ label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled)
        .padding(.horizontal)
        .padding(.bottom, 48)
    }

    private var stepAboutYou: some View {
        VStack(spacing: 0) {
            header("Over jou 💪", "Zodat je plan klopt.")
            Form {
                Section {
                    TextField("Naam", text: $name)
                        .focused($nameFocused)
                } footer: {
                    if showNameHint {
                        Text("Vul eerst je naam in 👆")
                            .foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Color.cleanCard)
                Section {
                    Stepper("Leeftijd: \(age)", value: $age, in: 14...80)
                    Stepper("Lengte: \(height) cm", value: $height, in: 120...220)
                    LabeledContent("Huidig gewicht") {
                        TextField("kg", value: $weight, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .listRowBackground(Color.cleanCard)
            }
            .scrollContentBackground(.hidden)
            nextButton("Volgende") {
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    withAnimation(.snappy(duration: 0.25)) { showNameHint = true }
                    nameFocused = true
                } else {
                    nameFocused = false
                    step = 1
                }
            }
        }
    }

    private var stepGoal: some View {
        VStack(spacing: 0) {
            header("Jouw doel 🎯", "Waar werk je naartoe?")
            Form {
                Section {
                    LabeledContent("Doelgewicht") {
                        TextField("kg", value: $goalWeight, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Deadline", selection: $goalDate, in: Date.now..., displayedComponents: .date)
                    Stepper("Training: \(trainings)×/week", value: $trainings, in: 1...7)
                }
                .listRowBackground(Color.cleanCard)
            }
            .scrollContentBackground(.hidden)
            nextButton("Maak mijn plan") {
                step = 2
            }
        }
    }

    private var stepPlan: some View {
        VStack(spacing: 0) {
            header("Jouw plan 📋", "Dit is wat er elke dag nodig is.")
            Form {
                Section {
                    LabeledContent("Gewicht", value: "\(rate >= 0 ? "+" : "")\(rate.formatted(.number.precision(.fractionLength(2)))) kg/week")
                    LabeledContent("Eiwit", value: "\(proteinTarget) g/dag")
                    LabeledContent("Training", value: "\(trainings)×/week")
                    LabeledContent("Doel", value: "\(goalWeight.kgText) kg op \(goalDate.formatted(date: .long, time: .omitted))")
                } footer: {
                    Text("Alles is later aan te passen via je profiel.")
                }
                .listRowBackground(Color.cleanCard)
            }
            .scrollContentBackground(.hidden)
            nextButton("Start") {
                guard !started else { return } // dubbel-tik = geen tweede profiel
                started = true
                context.insert(Profile(name: name.trimmingCharacters(in: .whitespaces), age: age, heightCm: height,
                                       startWeight: weight, goalWeight: goalWeight, goalDate: goalDate,
                                       trainingsPerWeek: trainings))
                context.insert(WeightEntry(kg: weight))
            }
        }
    }
}
