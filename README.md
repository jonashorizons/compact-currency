# Compact Currency

A native macOS menu bar currency calculator. Type an amount in any currency row and see the other rows update immediately. Compact Currency works offline with cached daily rates and keeps entered amounts on your Mac.

Requires macOS 14 or later. The build script targets the architecture of the Mac you build on.

## Build from source

Install the Xcode command-line tools, then run:

```sh
git clone https://github.com/jonashorizons/compact-currency.git
cd compact-currency
zsh scripts/build-app.sh
```

Move `build/Compact Currency.app` to `/Applications` and open it. The script ad hoc signs the app for local use.

## Use

- Click the ⇄ menu bar icon. **Right Command–Y** is available with the optional Karabiner rule below.
- **↑ / ↓** selects a currency and selects its entire amount. Type to replace it; conversions update immediately. Tab / Shift–Tab also moves between currencies.
- **Enter** formats and selects the amount. **Escape** closes the window. **Command–C** copies selected text.
- Amounts gain grouping commas as you type, without rounding the entered fractional digits or moving the caret to the end. Active amounts use normal contrasting text; selected text uses the native system selection colors.
- The **+** button opens currency search, selection and reordering. Settings includes decimal places, flags, refresh interval, launch at login, keyboard help and the rate source.
- The dropdown grows and shrinks with the selected list, without scrollbars or a ten-row limit. Only lists taller than the active screen are capped; wheel and arrow navigation still reach the remaining rows.
- Right-click the menu bar icon for Open, Refresh and Quit.

## Rates and privacy

[Frankfurter](https://frankfurter.dev/) supplies blended daily reference rates in a USD-based table. The app checks hourly by default. Settings offers four-hour and daily intervals as well as manual refresh. Settings shows the oldest quote date across your selected currencies and the currency you entered. Each row's tooltip shows its individual quote date.

The app calculates with `Decimal` and sends only a request for the rate table. It stores settings and the last successful table in `~/Library/Application Support/Compact Currency/`. A dated snapshot supports the first offline launch. When a refresh fails, the app keeps using its cached rates and labels them accordingly.

The rates are daily estimates. Check your bank or payment provider for the rate it will apply to a transaction.

## Menu bar managers

If you use Thaw, launch Compact Currency from `/Applications` so Thaw can display the menu bar icon reliably. See [Thaw's troubleshooting guide](https://www.getthaw.app/docs/thaw/frequent-issues#apps-running-outside-applications).

## Right Command shortcut

For an optional global shortcut, add [the example rule](integrations/karabiner-right-command-y.json) to Karabiner-Elements and enable it. It maps **Right Command–Y** to the app's registered hotkey and leaves **Left Command–Y** available to other apps.

To start Compact Currency automatically, enable **Launch at login** in Settings. macOS may ask for approval in **System Settings → General → Login Items & Extensions**.

## Tests

```sh
swift test
CURRENCY_LIVE_TEST=1 swift test --filter testLiveProviderSchema
```

For a native UI smoke test, run the built app's executable in an isolated state directory:

```sh
"build/Compact Currency.app/Contents/MacOS/CompactCurrency" \
  --smoke-test --state-directory="$(mktemp -d)"
```

The smoke test exercises amount editing, caret preservation, navigation, currency management and settings. It prints JSON and exits.

## License

[MIT](LICENSE)
