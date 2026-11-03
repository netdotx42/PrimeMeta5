# Deployment plan

Read [AUDIT.md](AUDIT.md) first. The findings that change how this EA should be hosted are H1 (a data gap skips the bar), H2 (several charts can enter together), H3 (the daily lock is per terminal and per chart), and M9 (algorithmic trading off does not flatten positions).

Public prices and rules below were read on 3 November 2026. Re-open the linked page before paying for anything. Figures that were not on those pages are marked uncertain.

## Recommendation

Run **one Windows VPS**, logged into the PrimeXBT MT5 Standard account, and do not leave the same account trading anywhere else.

This EA's daily baseline and lock are terminal global variables. They survive a restart of that same terminal (`gvariables.dat`) and they do not follow the account to a second machine. A Windows desktop on the VPS lets you open the global-variable list (F3), wait until H4 history is synchronized, and only then turn algorithmic trading on. That order is the practical mitigation for H1 until the source is changed: `OnInit` records the current M30 bar and will not trade it, and the next bar is evaluated only if the indicators can actually be read.

MetaQuotes Virtual Hosting is the runner-up when you do not want to patch Windows. It is a poor place to *start*, because migration turns algorithmic trading on immediately, the published migration list does not include global variables, and the hoster may take the terminal down for maintenance (weekends up to 4 hours a day on the EET calendar, weekdays up to 15 minutes). Details and the price table are in the MQL5 section below.

A PC on a desk is fine for compiling and for the Strategy Tester. It is a bad unattended host: sleep, Windows Update, and a home connection all look like H3 (the closer is simply not running). Linux under Wine is unsupported by the documents MetaQuotes publishes for the terminal and the compiler, and this repository has not run that combination. Do not use it for the live account.

Whatever you pick, the rollout order is the same: compile, Strategy Tester on the PrimeXBT server's history, demo forward test, then a small live account. One terminal only, from the demo onward.

## Comparison

| Option | Cost tier | Fits this EA | Main drawback |
| --- | --- | --- | --- |
| Windows PC at the desk | No extra host fee. Electricity, and the machine must stay awake. | Compile and Strategy Tester. Short supervised tests. | Not a 24/7 host. Sleep or reboot skips the closer (H3) and the current bar (H1, M8). |
| Windows VPS | Market rate for a small Windows server. Compare quotes with the published MQL5 price of USD 15 per month before choosing. No single public list price. | **Recommended** for demo and live. Full terminal, F3, you choose when algorithmic trading goes on. | You install updates yourself. Disconnecting RDP the wrong way (logging off, rather than disconnecting) closes the session. |
| MQL5 Virtual Hosting | Published on the price page: USD 15 for 1 month, USD 39 for 3 months (USD 13 per month), USD 65 for 6 months (USD 10.83 per month), USD 120 for 12 months (USD 10 per month). Up to 3 GB RAM, 16 GB disk, several CPU cores. | Usable. Four charts are inside the paid 32-chart migration cap. No DLL in this EA. | Algorithmic trading is forced on. Maintenance windows. No desktop. Global variables are not in the migration list. |
| Linux VPS and Wine | The Linux server only, often less than a Windows license. | Not recommended. | MetaQuotes documents MetaEditor and the terminal as Windows programs. This repo has not verified Wine. |

## Facts that constrain all four options

- The EA does not call a DLL and does not call `WebRequest`. The MQL5 VPS ban on DLLs does not, by itself, block this file ([rules III.9 and IV.6](https://www.mql5.com/en/vps/rules)).
- History for H4 EMA 200 is 201 H4 bars before the last closed bar can have a value, about 33.5 days of a 24-hour market ([AUDIT.md](AUDIT.md) I2). Open an H4 chart and scroll back, or wait for the journal to finish synchronizing, before judging the EA as "dead".
- PrimeXBT's Help Centre FAQ says a free demo exists and can be used on MT5 ([FAQ](https://primexbt.help/en/articles/8461245-frequently-asked-questions-f-a-q-platform-wide)). The public articles do not say that the demo's symbol strings, swaps, and filling mode match a live Standard account. Check them.
- PrimeXBT recommends website 2FA ([same FAQ](https://primexbt.help/en/articles/8461245-frequently-asked-questions-f-a-q-platform-wide)). The pages do not say whether the MT5 trade login asks for a one-time password on every connection. MQL5 Virtual Hosting cannot keep a session that needs a manual OTP each time it connects ([launch article](https://www.mql5.com/en/articles/13586)). Try one reconnect on a Windows VPS before you depend on it.
- Server name, hedging versus netting, stops level, freeze level, and contract size were not on the public pages. Read them in the terminal. Leave `RequirePrimeXBTServerName` false until the server string is in front of you.
- Swap, if the account is not swap-free, was published at 21:00 UTC in European summer and 22:00 UTC in European winter ([2024 post](https://primexbt.com/company-blog/important-information-regarding-swaps-on-primexbt-and-mt5/)). The EA's day boundary is the MT5 server clock (`TimeCurrent`), not that UTC timestamp, unless you have confirmed they are the same clock. A swap posting changes equity and can trip the 2% lock (M3).

## 1. Windows PC at the desk

Use this machine to compile, to run the Strategy Tester, and to watch a demo for an afternoon. Do not leave it as the live host.

1. Install PrimeXBT's MT5 package, or the MetaQuotes terminal from [download.mql5.com](https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe), and log in with the trading password. An investor password can look at the account and cannot trade; this EA does not detect that at init.
2. Market Watch → Show All. Confirm `BTCUSDT`, `ETHUSDT`, `SOLUSDT`, and `BNBUSDT` character for character. If a name differs, put the real name in `AllowedCryptoSymbols`. Do not add `BASE` unless you have confirmed the instrument; the owner's note left it out on purpose.
3. Open each symbol's specification. Write down digits, point, tick size, volume minimum and step, stops level, freeze level, filling mode, trade mode (full / long only / short only / close only), swap long and swap short, and margin mode (hedging or netting).
4. File → Open Data Folder. Copy `Crypto_4H_30M_Pullback_MT5.mq5` to `MQL5\Experts\PrimeMeta5\`.
5. MetaEditor → open the file → F7. The log must say 0 errors. Warnings, if any, get read before you continue. `#property strict` is an MQL4 line; if this build warns about it, that warning is I1, not a logic change.
6. On each symbol, open an H4 chart, turn to the start of the history, and wait until the chart actually draws. Then attach the EA. Chart period can be M30. Inputs stay at the defaults for the first demo run.
7. Turn algorithmic trading on only while you are watching. Toolbox → Experts should show the baseline line.
8. When you stop for the day, close the positions yourself if any are open, then turn algorithmic trading off. M9: the button does not flatten.

Power settings: sleep and hibernate unload the terminal. A laptop lid is not a host.

## 2. Windows VPS

Recommended for the unattended demo and for live.

1. Rent a small Windows Server or Windows desktop VPS. Prefer a region you can RDP to reliably. PrimeXBT's trade-server city was not on the pages read, so "close to the broker" is something you measure (ping the trade server from the VPS), not a city this document can name.
2. Connect with Remote Desktop. When you are done for the session, disconnect. Do not log off, and do not shut the VPS down, unless you intend the EA to stop.
3. Turn on Windows Time service (NTP). The daily key follows ticks, not the Windows clock. `TimeTradeServer`, which the news filter uses, does follow the local clock's offset from the server. A wrong clock still makes the terminal logs miserable to read.
4. Install MT5 as in the PC section. Log in to the Standard account. Store the password in the terminal's account list so a reboot can reconnect. If a reconnect pops an OTP you cannot answer remotely, this VPS cannot host the account unattended. That OTP behavior was not documented; test it.
5. Compile on this VPS with its own MetaEditor, so the `.ex5` matches the terminal build. A GitHub artifact is a compile check, not the file to copy onto a different build. See the CI section.
6. Download history (step 6 of the PC section) **before** you enable algorithmic trading. Attach the four charts. Confirm four Experts-log lines and, in Tools → Global Variables (F3), one `PXBTSTD_CRYPTO_<login>_<YYYYMMDD>_BASE` for today.
7. Tools → Options → Expert Advisors. Allow algorithmic trading. Look at the three "disable algorithmic trading when the account / profile / symbol changes" boxes. A reboot that trips one of them leaves positions open and blocks both new entries and the daily closer (M9). After the first reboot, confirm the toolbar button is still on.
8. Disable algorithmic trading on every other terminal that is logged into this account, including the PC you used to compile. Two terminals are two baselines (H3).
9. Optional watchdog, outside the EA: a scheduled task that checks `terminal64.exe` is running and starts it if not. Keep it boring. Do not run a second copy "just in case".
10. Plan restarts for when you can watch the next M30 open. A restart skips the bar that is already forming (M8). Hoster-style surprise reboots are the thing a Windows VPS lets you avoid, if you patch on your own schedule.

Cost: shop current Windows VPS prices. A 2 GB instance is enough for four charts and no heavy indicators; this is a judgment about this EA's footprint, not a vendor minimum. Put that quote next to USD 15 per month for MQL5 hosting and pick with the operational differences in mind, not the price alone.

## 3. MQL5 Virtual Hosting

MetaQuotes rents a virtual terminal on a hoster's machine. You start the rental from the desktop terminal. You do not get a remote desktop. Rules: [mql5.com/en/vps/rules](https://www.mql5.com/en/vps/rules). Prices: [mql5.com/en/vps/forex-plans](https://www.mql5.com/en/vps/forex-plans). A walkthrough of migration: [MQL5 article 13586](https://www.mql5.com/en/articles/13586).

Published price table on 3 November 2026:

| Plan | Total | Per month |
| --- | --- | --- |
| 1 month | USD 15 | USD 15 |
| 3 months | USD 39 | USD 13 |
| 6 months | USD 65 | USD 10.83 |
| 12 months | USD 120 | USD 10 |

The same page says each virtual platform can use up to 16 GB of disk, up to 3 GB of RAM, and several CPU cores, and that a cancellation inside the first 24 hours is fully refunded. The rules say a user can cancel with no refund (IV.4, VI.5). Read the text the terminal shows at the moment you pay. The rules still mention a free hosting tier capped at 16 charts; the price page lists only the paid plans. Do not assume this account qualifies for the free tier.

What you get that matters here:

- The host runs 24 hours. Maintenance is allowed: weekends up to 4 hours a day, EET, and weekdays up to 15 minutes ([rules II.3](https://www.mql5.com/en/vps/rules)). During that time this EA does not tick and does not close (H3).
- One rented terminal, one trading account. The same account is allowed on more than one virtual terminal ([rules III.4](https://www.mql5.com/en/vps/rules)). Do not do that with this EA.
- Synchronization is manual and one-way, local terminal → virtual terminal. Nothing on the VPS syncs back ([rules III.7 and section V](https://www.mql5.com/en/vps/rules)).
- Migrated environment, as listed: account login, Market Watch, charts that have an EA (paid cap 32, free cap 16), the EA's inputs, the compiled EX5, FTP/email/notification settings, WebRequest permissions, and up to 500,000 bars on the chart. Charts with no EA are not migrated. Scripts are not migrated.
- Terminal global variables are **not** in that list. Assume the VPS starts with an empty baseline and creates one from equity at the first tick (H3, M1).
- Algorithmic trading is always on in the virtual terminal, even if it is off locally ([rules, section V](https://www.mql5.com/en/vps/rules); [article](https://www.mql5.com/en/articles/13586)).
- The first synchronization uploads history, and EAs are expected to cope with data that is still arriving. This EA does not (H1). The first M30 bars after migration can be skipped with no log line.
- DLL calls stop the program. This EA does not make one.
- You read logs by requesting them back into the desktop terminal. You cannot open F3 on the VPS.
- MetaQuotes says it is the technology provider, that the hoster owns the hardware, and that smooth operation is not guaranteed ([rules I.11 and VII](https://www.mql5.com/en/vps/rules)).

Steps:

1. On the Windows PC, finish the compile, attach the EA to the four symbol charts you actually want, and delete every other chart. Charts without an EA are dropped. Extra charts with an EA count toward the cap and toward CPU.
2. Confirm each Experts log shows a normal init, not `INIT_FAILED`.
3. In the terminal, open the VPS section and rent a server. The terminal offers a hoster; this document does not rank hosters.
4. Migrate with the Experts migration (not a signal subscription). This EA does not copy signals.
5. Immediately turn algorithmic trading **off** on the local PC, or close the local charts. Both terminals would trade (H3). The VPS copy stays on. That is the rules, not a setting you can flip on the VPS.
6. Request the virtual terminal's Experts log. You want four inits and a baseline line. You will not see F3. If the log shows `CopyBuffer` silence and no trades for several M30 bars, that is consistent with H1 during the history upload. The next bar after history is ready can trade. It is not evidence the signal is profitable.
7. To change an input or a build: change the local charts, compile, then synchronize again. The previous virtual environment is replaced by the local one.
8. To stop trading: stop or cancel the rental from the desktop terminal, and also confirm the local button is off. Cancelling does not close broker positions. Close those yourself.
9. A stopped rental does not extend the paid period ([rules IV.5](https://www.mql5.com/en/vps/rules)).

Use this path after a Windows or local demo has already shown fills, stops, and a midnight rollover. Using it as the first host hides the global variables you most need to see.

## 4. Linux VPS and Wine

MetaEditor's command-line help shows `metaeditor64.exe` and Windows paths ([Integration with other IDEs](https://www.metatrader5.com/en/metaeditor/help/beginning/integration_ide)). The Virtual Hosting rules describe a MetaTrader terminal, not Wine. This repository's compile workflow uses a Windows runner for that reason. Wine is a compatibility layer people do run MT5 under. It is not a configuration this repo has installed, compiled, or traded on.

If you experiment anyway, keep it on a demo, expect the installer and the next MT5 upgrade to be the fragile parts, and do not point a live Standard account at it while the daily lock is something you intend to trust. A failed Wine process is H3 with extra steps. No step-by-step is given here on purpose: a half-working recipe would read as a recommendation.

Uncertain: which Wine version currently runs the current MT5 build. Not checked.

## Staged rollout

Do these in order. Do not skip to live because a tester graph slopes up.

### Stage A. Compile

On the Windows machine from section 1 or 2: F7, 0 errors. Read every warning. The CI workflow, if it is green, is a second opinion from a clean MetaQuotes install. It is not a substitute for compiling on the terminal you will leave running. Status of that workflow is at the bottom of this file.

### Stage B. Strategy Tester, on the PrimeXBT trade server

The tester loads history from the trade server the terminal is logged into ([Testing](https://www.mql5.com/en/docs/runtime/testing)). Log into the PrimeXBT account first so the bars and ticks are that server's, not another broker's file you imported.

1. View → Strategy Tester. Expert: `Crypto_4H_30M_Pullback_MT5`. Symbol: `BTCUSDT` (then repeat the other three). Period: M30 is a reasonable chart period; the EA reads H4 and M30 itself.
2. Model: **Every tick based on real ticks**. Where the broker has no ticks for a minute, the tester fills in generated ticks. That substitution is in the testing chapter; it means "real ticks" is only as complete as PrimeXBT's archive. This audit did not find a public statement of how much tick history PrimeXBT keeps.
3. Do not use **Open prices only**. The same chapter says that mode fits strategies that do not use stop loss or take profit. This EA uses both. A good curve in that mode is not evidence.
4. "1 minute OHLC" is a smoke test. If it looks much better than real ticks, believe the real-tick run.
5. Start date: at least 40 calendar days after the first H4 bar in the file, and preferably several months later, so EMA 200 exists and is not brand new (I2).
6. Deposit and leverage: match the account you will actually use. Copy swap long, swap short, and any commission or fee from the symbol specification into the tester. Published text says MT5 Standard crypto is spread-only and that help articles also mention administrative fees ([AUDIT.md](AUDIT.md) M2). Type what the specification says. Do not leave the tester default and call it PrimeXBT.
7. Spread comes from the historical bars in this tester. It is not today's live quote.
8. Run one symbol at a time. The daily lock, the baseline race, and four correlated entries do not exist in this test (M7). Write that on the result so nobody treats the graph as the 2% control.
9. In visual mode for a short slice, confirm a long only after a bullish M30 close back above EMA 20 and through the prior high, with H4 EMA 50 above EMA 200, and a target about twice the stop distance. That is a logic check, not a performance check.

### Stage C. Demo forward test

1. Use the PrimeXBT MT5 demo the FAQ describes. Confirm the four symbol strings and write down how the demo's stops level, filling mode, and swap differ from live, if they differ.
2. One Windows terminal (the VPS, once you trust the compile). Four charts. Defaults are acceptable on a demo because the loss is play money. `RequirePrimeXBTServerName` stays false until you have read the server string.
3. Leave it across at least one server midnight and one deliberate restart.
4. After midnight, F3 should show a **new** date in the key, and the Experts log should show a new baseline. The old key is still there (L1). That is expected with this source.
5. After the restart, the forming M30 bar must not trade (M8). The following bar may.
6. If you can do it without wrecking the demo account, withdraw or deposit a small play amount and watch whether the equity change moves the lock (M3). On a live account, do not discover this by accident.
7. Confirm a filled position has a non-zero stop and target (M5). Confirm the filling mode you logged at init was accepted.
8. Stop the test by closing positions in the Trade tab, then turning algorithmic trading off.

How long: long enough to see several signals and one daily reset. No number of days makes a demo into a track record. The point of this stage is the operational behavior in the audit, not a profit factor.

### Stage D. Small live

1. Same single Windows VPS. Same "nothing else is logged in and trading" rule.
2. Start with **one** symbol, not four, so H2 cannot stack a full set on day one. Pick the symbol whose specification you understand (minimum volume in particular). If the minimum lot's stop loss is larger than `RiskPercent` of equity, the EA prints "minimum volume exceeds risk budget" and skips. On a small account that can be every bar. Raise equity or choose a symbol with a smaller minimum; do not edit the EA to force the minimum lot. The source refuses it on purpose.
3. For the first live weeks, set `RiskPercent` below 0.5 if you want a smaller experiment. That is an input, not a source change. Four times the input is still the stack you get once all four charts are on.
4. Add the other symbols only after one symbol has opened, shown a stop and a target, and passed a midnight reset.
5. The first time the lock prints "Daily loss limit hit", confirm every symbol is flat or being closed, and do not delete the `LOCK` global variable to "re-enable" the day. Deleting it is how the control is turned off.
6. Keep the desktop PC's algorithmic trading button off for the life of the VPS run.

## Operational checklist

### Before leaving it alone

- [ ] One terminal, one account, algorithmic trading on in exactly that terminal.
- [ ] Four charts (or fewer, on purpose), one EA each, magic `4260926` unless you changed it.
- [ ] Experts log shows init and a positive baseline. F3 shows today's `BASE` key. There is no `BASE` equal to 0 (M4).
- [ ] Specification notes are written down: filling mode, trade mode, stops level, freeze level, volume step, swap, hedging or netting.
- [ ] H4 history is present (scroll an H4 chart back more than 201 bars).
- [ ] A reboot test: button comes back on, EA comes back, current bar is not traded.
- [ ] You know how to close a position from the Trade tab without using the Algo Trading button as a flatten switch (M9).

### Every day

- [ ] Experts log and the Journal, not only the chart. Look for "Order failed", "Position close failed", "baseline set to 0", "minimum volume exceeds risk budget", "margin cap".
- [ ] Open position count is at most one per symbol for this magic. Two on the same symbol means a double chart or a hedging account plus something else sending.
- [ ] Equity drawdown versus the F3 baseline. The lock trips at 2% and then stays for the server date even if equity recovers.
- [ ] The VPS is reachable and `terminal64.exe` is running. A host that is up and a terminal that is not are different.

### Logs, alerts, restarts, updates

Logs:

- Expert output: the data folder's `MQL5/Logs`, and Toolbox → Experts.
- Terminal connection and trade-server messages: the data folder's `Logs`, and Toolbox → Journal.
- This EA uses `Print` only. It does not call `SendNotification`, email, or `Alert`. A daily lock, a failed close, and a skipped bar will not push to your phone unless you add that later. Until then, the checklist is the monitor. The terminal's own push settings do not fire unless the program asks for them.
- On MQL5 Virtual Hosting, request the Experts and terminal journals from the VPS section of the desktop terminal ([rules III.8](https://www.mql5.com/en/vps/rules)).

Alerts worth adding later, not in this tree: `Alert` plus a push on protective-close failure, on a new lock, and on init failure. That is a source change.

Restarts:

- Windows Update: active hours, and a manual reboot when you can watch the next M30 bar. Confirm the Algo Trading button afterwards.
- MT5 update: the terminal restarts itself on many builds. Same check. Recompile if MetaEditor updated and you are about to change the source. An existing `.ex5` keeps running; you do not have to recompile just because the terminal moved a build, but you should confirm the EA is still attached and the button is on.
- After any restart, the forming bar is skipped. That is the current source. One missed signal is the price of the restart. A restart during a daily-lock close is worse: the closer only runs while the terminal is up (H3). Prefer to restart when the book is flat.

Updates to the EA:

- This repository's source is v1.30 unchanged. A future patch from [AUDIT.md](AUDIT.md) should be a separate change, compiled, then walked through stages B–D again. Do not drop a new `.ex5` onto a live book and assume open positions will be adopted. The source does not modify positions it did not just open, but it will close positions of the same symbol and magic when the lock or the end-of-day input says so.
- Inputs persist per chart. Changing them re-runs `OnInit`, which records the current bar and skips it, and which will not reset an existing baseline key.
- Synchronize an MQL5 VPS again after any local change. It does not pick up files on its own.

Emergency:

1. Close the positions in the Trade tab (or with a one-off script you trust). Do not rely on the Algo Trading button.
2. Then turn algorithmic trading off, or stop the VPS rental.
3. If you turn the button back on the same server day, a `LOCK` key that already exists will start closing again as soon as ticks arrive. That is what the key is for. Remove it only if you intend to trade again the same day, and write down why.

## CI compile workflow

File: [`.github/workflows/compile-ea.yml`](../.github/workflows/compile-ea.yml).

What it is supposed to do:

1. On `windows-latest`, download `mt5setup.exe` from MetaQuotes.
2. Accept the file only when Authenticode status is `Valid` and the publisher name contains `MetaQuotes`. The installer body changes per download, so there is no pinned hash.
3. Run `mt5setup.exe /auto`, then search for `metaeditor64.exe`.
4. Find `Include\Trade\Trade.mqh`, copy the EA under that tree's `Experts\PrimeMeta5\`, and compile with the documented flags `/compile`, `/include`, and `/log` ([MetaEditor Help](https://www.metatrader5.com/en/metaeditor/help/beginning/integration_ide)).
5. Pass the job when the Unicode log contains `0 error` and an `.ex5` exists. The process exit code is logged and ignored. A MetaEditor build has been reported to return the number of files compiled, so a successful one-file compile can exit 1 ([forum report](https://www.mql5.com/en/forum/519259)). That report is not MetaQuotes' documentation; the log is the check.
6. Upload the `.ex5` and `compile.log` as the artifact `Crypto_4H_30M_Pullback_MT5-ex5`.

The workflow runs on pull requests, on pushes to `main` and `cursor/**`, and on manual dispatch.

### Verification status

**Verified once, on 3 November 2026.** [Actions run 41741433862](https://github.com/netdotx42/PrimeMeta5/actions/runs/41741433862) completed green on `windows-latest`. The compiler log says:

`Result: 0 errors, 0 warnings, 1114 ms elapsed, cpu='X64 Regular'`

The `.ex5` and that log were uploaded as the artifact `Crypto_4H_30M_Pullback_MT5-ex5`. MetaEditor's process exit code was 1. On that build the exit code tracked the file count, not the error count, which is why the workflow trusts the log. `#property strict` produced no diagnostic. `Trade.mqh` was included from `C:\Program Files\MetaTrader 5\MQL5\Include\Trade\Trade.mqh` after `terminal64.exe /portable` unpacked it. The log does not print a terminal build number.

Two earlier runs on the same day failed in the workflow, not in the EA, and those failures are why the script looks the way it does:

- [41740874904](https://github.com/netdotx42/PrimeMeta5/actions/runs/41740874904) installed MetaEditor and did not find `Trade.mqh`, because `/auto` does not unpack the standard library until the terminal has started.
- [41741152944](https://github.com/netdotx42/PrimeMeta5/actions/runs/41741152944) found `Trade.mqh` and passed `/include` the `Include` directory. MetaEditor then looked for `Include\Include\Trade\Trade.mqh` and reported `error 106` (file not found). The documented `/include` value is the `MQL5` directory.

A later push re-runs the job. A green badge on an older commit is not a green badge on a commit that changes the `.mq5`. This verification is for the v1.30 bytes compiled in run 41741433862.

Compile for live on the trading terminal even so. The artifact proves the MetaEditor downloaded that day accepted the file. It does not prove that compiler build is the one installed on the VPS. The installer is still a network stub, and a future image or a future `mt5setup.exe` can break the job without the EA changing.

## Source list

Read 3 November 2026.

- [MQL5 Virtual Hosting rules](https://www.mql5.com/en/vps/rules)
- [MQL5 Virtual Hosting prices](https://www.mql5.com/en/vps/forex-plans)
- [Launching MetaTrader VPS](https://www.mql5.com/en/articles/13586)
- [Testing trading strategies](https://www.mql5.com/en/docs/runtime/testing)
- [MetaEditor, compiling from the command line](https://www.metatrader5.com/en/metaeditor/help/beginning/integration_ide)
- [PrimeXBT FAQ (demo, MT5 fees, 2FA)](https://primexbt.help/en/articles/8461245-frequently-asked-questions-f-a-q-platform-wide)
- [PrimeXBT trading conditions (6 August 2026)](https://primexbt.help/en/articles/16240701-trading-conditions-explained)
- [PrimeXBT spread-only change (5 September 2025)](https://primexbt.com/company-blog/crypto-cfds-on-pxtrader-and-mt5-are-now-spread-only/)
- [PrimeXBT swap clock (2024)](https://primexbt.com/company-blog/important-information-regarding-swaps-on-primexbt-and-mt5/)
- [PrimeXBT MT5 crypto CFD list (6 May 2025)](https://primexbt.com/company-blog/crypto-cfds-now-available-on-mt5-with-expanded-instrument-selection/)
