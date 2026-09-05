# Proposal for for-Jamf: tighter menu bar item spacing on every ForIT Mac

Written by for-Wingman on 2026-09-05. Ben: "Can we turn the default doc menu bar spacing on for all of our Macs to small? Will that interfere with Barbie [Bartender]? … look at Christine's messages, I don't think that she sees the thing there."

## The problem

Wingman lives only in the menu bar. On a MacBook with a notch, macOS hides any status item that does not fit to the right of the notch, with no indication that it is hidden. Christine's messages read as though she cannot see the Wingman icon at all. The default spacing between status items is generous, so a Mac with a dozen menu bar apps runs out of room early.

## What macOS offers

Two undocumented but long-stable global defaults (macOS 11 onward, still honoured on macOS 15) control the spacing:

| Key | Default | What it does |
|-----|---------|--------------|
| `NSStatusItemSpacing` | 16 | Points between neighbouring status items |
| `NSStatusItemSelectionPadding` | 16 | Extra width added to each item's highlight |

Both are per-host, so they must be written with `-currentHost` into the global domain:

```sh
defaults -currentHost write -globalDomain NSStatusItemSpacing -int 6
defaults -currentHost write -globalDomain NSStatusItemSelectionPadding -int 6
```

They take effect at the next login (a logout, not a restart, is enough; `killall SystemUIServer` no longer reads them). Values below 6 make adjacent icons touch. To undo:

```sh
defaults -currentHost delete -globalDomain NSStatusItemSpacing
defaults -currentHost delete -globalDomain NSStatusItemSelectionPadding
```

## Bartender

Bartender 5's "Menu bar item spacing" setting writes the same two keys. The last writer wins, so:

- A Mac with Bartender set to a spacing keeps whatever Bartender wrote last. A Jamf policy that writes 6 would be overwritten the next time the person changes the Bartender setting, and Bartender's own value would be overwritten by the next policy run.
- Bartender's hidden-items feature does not depend on these keys; it keeps working at any spacing.

Recommendation: scope the policy to Macs without Bartender installed (a Smart Group on `/Applications/Bartender 5.app` absent), and leave Bartender users to their own setting. Bartender users can already reach a hidden Wingman icon through Bartender's bar.

## Proposed policy

1. A Jamf script that runs as the console user (`launchctl asuser` with the console uid, or `sudo -u`), because `-currentHost -globalDomain` is per user, writing both keys to 6.
2. Once per Mac, ongoing frequency, with an Extension Attribute reading `defaults -currentHost read -globalDomain NSStatusItemSpacing` so a Smart Group can show which Macs have it.
3. A notification that the change appears at next login.
4. Scope: all ForIT Macs without Bartender, Christine's first.

## What Wingman does on its side

Nothing in Wingman can force its icon to be visible; macOS decides what fits. Wingman's icon is a template glyph at the standard width, and the panel also opens on its own when something needs attention (first run, a revoked permission, the usage notice). A person who cannot find the icon can still use push-to-talk (ctrl+option), which does not need the icon.

Cross-project writes are not made from for-Wingman; this file is the proposal for for-Jamf to act on.
