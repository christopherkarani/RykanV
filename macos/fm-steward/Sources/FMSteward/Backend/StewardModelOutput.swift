#if canImport(FoundationModels)
import FoundationModels

/// Structured generation target for the on-device System Language Model.
///
/// Constrained via guided generation so the model cannot invent free-form
/// verdict strings outside the product enum. **v1:** shell / command danger.
@Generable(description: "ryk FM steward classify decision for a shell/command risk card")
struct StewardModelOutput {
    @Guide(
        description: "Soft-interrupt decision for a shell or agent command",
        .anyOf(["continue", "ask", "ask_sticky_candidate"])
    )
    var verdict: String

    @Guide(description: "One short sentence why this verdict was chosen (no secrets)")
    var why: String

    @Guide(
        description:
            "Plain-language user explanation when verdict is ask or ask_sticky_candidate; empty string when continue"
    )
    var explain: String

    @Guide(
        description:
            "Sticky allow scope only when verdict is ask_sticky_candidate; otherwise empty. One of: once, session, effect_class, or empty",
        .anyOf(["", "once", "session", "effect_class"])
    )
    var suggestedStickyScope: String

    @Guide(
        description:
            "Effect class for sticky when suggestedStickyScope is effect_class; otherwise empty. Prefer shell, file, or network",
        .anyOf(["", "shell", "file", "network"])
    )
    var suggestedEffectClass: String
}
#endif
