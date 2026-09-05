//
//  WingmanQuitCommand.swift
//  Wingman
//
//  "Quit Wingman" by voice (decision 017). Ben, 2026-09-05: "I think we also need a command to
//  like quit wingman." The one tool that ends the app: the model calls it when the person asks
//  Wingman to quit, the app answers that it will quit once the goodbye has been spoken, and
//  CompanionManager terminates the app after the last sentence of that turn has played.
//  Nothing is sent anywhere and nothing else is closed.
//

import Foundation

enum WingmanQuitCommand {
    static let toolName = "quit_wingman"

    /// The tool as described to the model. It takes no argument: quitting is quitting.
    static let modelToolDefinition: [String: Any] = [
        "name": toolName,
        "description": "Quit Wingman, this menu bar app, on the user's Mac. Call it only when the user asks Wingman itself to quit, close, exit, shut down or go away. It does not close any other application and cannot be undone by voice: the user reopens Wingman from the Applications folder. After calling it, say a one-sentence goodbye and nothing else.",
        "input_schema": [
            "type": "object",
            "properties": [String: Any](),
            "additionalProperties": false
        ]
    ]

    /// The rules the system prompt carries for this tool.
    static let systemPromptSection = """


    QUITTING WINGMAN: when the user asks wingman itself to quit, close, exit or go away ("quit wingman", "close yourself", "wingman, shut down"), call quit_wingman, then say a one-sentence goodbye and stop; do not call any other tool in that turn. "quit safari" or "close this window" is not this: those are other apps and wingman does not close them.
    """

    /// What the model reads back after the call: the app quits once the goodbye has been spoken,
    /// so the model's next words are the last thing the person hears.
    static let modelResultText = "Wingman will quit as soon as you have finished speaking. Say a one-sentence goodbye now and call no other tool."

    /// The delay between the last spoken sentence and the quit, so the usage report of the turn
    /// (posted in its own task) has a moment to leave and the person hears the goodbye end.
    static let quitDelayAfterGoodbye: Duration = .seconds(1)
}
