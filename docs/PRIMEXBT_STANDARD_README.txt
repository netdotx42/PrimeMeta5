PRIMEXBT MT5 STANDARD — CRYPTO H4/M30 PULLBACK EA v1.30

Original entry logic preserved:
H4 EMA(50)/EMA(200) trend; M30 EMA(20) pullback, bullish/bearish closed candle and previous-candle breakout. Swing stop, 2R target, equity-based position sizing.

PrimeXBT Standard-specific adaptations:
- Explicit symbol allowlist: BTCUSDT, ETHUSDT, SOLUSDT, BNBUSDT. Exact symbols must be visible in Market Watch. No automatic Pro suffix or symbol substitution.
- BASE deliberately excluded; no confirmed BASE instrument or token.
- Position sizing uses OrderCalcProfit with the broker's symbol contract, lot step and currency conversion.
- Margin is verified with OrderCalcMargin and limited to 30% of account equity by default.
- Broker stop-level checks use live bid/ask (not only entry price).
- EA refuses to open trades on symbols with an existing net position.
- Shared account-level daily equity baseline and lock across charts using this EA. Daily loss 2% by default, closes only this EA's magic-number positions per chart on subsequent ticks; it does NOT guarantee a portfolio-wide liquidation of positions if charts are offline. The baseline is initialized when the first EA starts each broker-server day, NOT necessarily midnight.
- ATR-based spread and volatility checks; 24/7 entries; no forced end-of-day close.
- RestrictToPrimeXBTStandardSymbols=true by default. RequirePrimeXBTServerName=false because broker server naming varies; optionally enable after checking server identification.

INSTALL:
1. In PrimeXBT MT5 Standard, Market Watch > Show All and verify symbols and contract specs.
2. Copy .mq5 to File > Open Data Folder > MQL5 > Experts.
3. Open in MetaEditor and press F7. Resolve any compilation messages before proceeding.
4. Attach one instance to each permitted crypto chart, enable Algo Trading. H4/M30 data is read automatically; chart timeframe can be M30.
5. Backtest separately on PrimeXBT historical ticks and spreads, then forward-test on demo.

IMPORTANT:
- This code was not compiled or backtested in MT5 here; no profitability or broker execution is guaranteed.
- 0.5% risk is PER POSITION, not total portfolio risk. Four simultaneous entries could risk ~2% before slippage, gaps and swap costs.
- Broker symbol trading sessions, swaps, contract details, stops, spreads and fills may change.
- Trading volume/turnover targets shown in account promotions are not trading signals; do not force trades.
- EA does not automatically modify existing positions or migrate earlier trades.
