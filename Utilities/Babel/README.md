# Babel

Translates everything foreign on screen into English, drawn in place over the original: same
spot, background, text color, size and line spacing. Slack messages, screenshots and PDFs in
Slack, emails, web pages: if it's on screen, it works.

- **⇧⌘2**: translate the display under the pointer. Again, or **Esc**, to put it back.
- **Hold ⌥**: see the original. **Click** a translation to copy it; **Copy all** in the pill
  copies every one, in reading order.
- Clicking anywhere else, scrolling or switching apps also puts the screen back.
- `open babel://translate` does the same as the shortcut, for Raycast, Shortcuts or a Stream Deck.

The source language is detected per paragraph (German, Dutch, French, Spanish, Italian, …, and
several on one screen); English is left alone, and so are names and labels. **Settings…** in the
menu changes the shortcut, the language to translate into and the quality (**Fast**, or **Best**:
slower, and a few more languages).

Everything runs on the Mac: Apple's on-device text recognition (Vision) and translation, so
nothing on screen leaves it. It needs macOS 26.4 or later, and Screen Recording permission (asked
for in Settings on first launch). The first translation after installing or updating can take up
to a minute while Vision prepares its models; after that it's about a second.

## How it works

Capture (ScreenCaptureKit) → paragraphs (Vision `RecognizeDocumentsRequest`) → which are foreign
(NaturalLanguage) → translate (Translation) → each translation laid out over its original.

- Paragraphs, not lines, so whole sentences are translated, then re-wrapped into the original
  box with its indents, line pitch and alignment. Lines Vision splits apart are joined again when
  they're clearly one sentence.
- Big displays are read in overlapping bands in parallel: on a 6K display Vision would otherwise
  shrink small text to garbage. It reads an inverted copy too, since it misses light text on dark
  areas of light screens (and the reverse).
- Languages: which ones are on screen comes from full sentences only. A short label is translated
  when it sits by foreign prose ("Hallo Anna," over a German message) or most of the screen is
  foreign, so a name like "Anna" or Slack's B I U S toolbar stay as they are.
- Font size comes from setting the original line in the system font and matching its width;
  colors are sampled around and inside each paragraph. A longer translation grows into empty
  background before it shrinks.

`Babel --translate-image <image> -o out.png` (or `--screen`) runs it on an image and writes the
result, for working on it. In dev builds, `defaults write com.ckafrouni.babel.dev debugImage <image>`
makes the app translate that image instead of the screen.
