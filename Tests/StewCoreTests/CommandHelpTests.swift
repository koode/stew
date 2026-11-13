import StewCore
import Testing

struct CommandHelpTests {
    let usage = """
    stew: sample.

    USAGE
      stew permit --action TEXT --reason TEXT [common]
      stew needs TITLE [--why TEXT]
          Tell the user you need them.
      stew needs list [--json]       The open items.
      stew stop          Stop the daemon.

    COMMON
      --session NAME     Label for the panel.
      --timeout SECONDS  Time to answer.
    """

    @Test func helpIsRequestedByEitherFlag() {
        #expect(CommandHelp.isRequested(["--action", "x", "--help"]))
        #expect(CommandHelp.isRequested(["-h"]))
        #expect(!CommandHelp.isRequested(["--action", "help"]))
    }

    @Test func commandWithCommonFlagsGetsTheCommonSection() {
        let help = CommandHelp.text(for: "permit", usage: usage)
        #expect(help == """
        USAGE
          stew permit --action TEXT --reason TEXT [common]

        COMMON
          --session NAME     Label for the panel.
          --timeout SECONDS  Time to answer.
        """)
    }

    @Test func everyFormOfACommandAndItsExplanationAreKept() {
        let help = CommandHelp.text(for: "needs", usage: usage)
        #expect(help == """
        USAGE
          stew needs TITLE [--why TEXT]
              Tell the user you need them.
          stew needs list [--json]       The open items.
        """)
    }

    @Test func unknownCommandHasNoHelp() {
        #expect(CommandHelp.text(for: "bogus", usage: usage) == nil)
        #expect(CommandHelp.text(for: "stop", usage: usage) == "USAGE\n  stew stop          Stop the daemon.")
    }
}
