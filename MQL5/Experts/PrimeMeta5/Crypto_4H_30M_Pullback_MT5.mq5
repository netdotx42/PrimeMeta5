#property strict
#property version "1.40"
#property description "H4 trend + M30 pullback crypto EA with ATR and spread protection"

#include <Trade/Trade.mqh>

CTrade trade;

// ---- Strategy settings ----
input double RiskPercent       = 0.5;
input bool   RestrictToPrimeXBTStandardSymbols = true;
input bool   RequirePrimeXBTServerName = false; // broker server labels vary
input string AllowedCryptoSymbols = "BTCUSDT,ETHUSDT,SOLUSDT,BNBUSDT";
input double RewardRisk        = 2.0;
input int    TrendFastEMA      = 50;
input int    TrendSlowEMA      = 200;
input int    EntryEMA          = 20;
input int    SwingLookback     = 5;
input int    StopBufferPoints  = 10;
input ulong  MagicNumber       = 4260926;
input int    DeviationPoints   = 20;

// ---- Optional crypto enhancements (original entry conditions unchanged) ----
input bool   UseATRStopBuffer  = true;
input int    ATRPeriod         = 14;
input double ATRBufferMultiple = 0.20;
input double MinATRPercent     = 0.10;  // 0 disables low-volatility filter
input double MaxATRPercent     = 8.00;  // 0 disables high-volatility filter
input double MaxSpreadATRRatio = 0.10;  // 0 disables spread/ATR filter
input double MaxStopATRMultiple = 5.0;  // 0 disables excessively wide stop filter
input bool   RequireH4PriceSide = false; // optional stricter trend confirmation
input bool   EnableMarginCheck = true;
input double MaxMarginEquityPercent = 30.0;


// ---- Trading filters ----
input bool   AllowBuy          = true;
input bool   AllowSell         = true;
input int    MaxSpreadPoints   = 0;      // 0 = disabled
input bool   EnableNewEntries  = true;

// ---- Daily loss protection ----
input double DailyLossLimitPercent = 2.0; // 0 = disabled; equity vs daily baseline

// ---- Economic news filter ----
input bool   EnableNewsFilter  = false; // crypto defaults: optional USD macro-news filter
input string NewsCurrencies    = "USD,EUR,GBP";
input int    NewsMinutesBefore = 30;
input int    NewsMinutesAfter  = 30;

// ---- End-of-day close (broker server time) ----
input bool   EnableEndOfDayClose = false; // crypto trades continuously
input int    CloseHour           = 23;
input int    CloseMinute         = 45;

// ---- v1.40 risk controls (entry conditions are unchanged) ----
input int    MaxEntryDelaySeconds = 20;       // H1/M8. Retry this many seconds after the M30 open. Then skip and log.
input int    MaxOpenPositions = 4;            // H2. Our magic, all symbols. 0 disables the count.
input double MaxTotalRiskPercent = 2.0;       // H2. Open stop-risk plus the new trade, percent of equity. 0 disables.
input double ExtraCostPerLot = 0.0;           // M2. Extra account-currency cost per 1.0 lot (commission + fee). 0 = price distance only.
input bool   ExcludeNonTradeCashflows = true; // M3. Ignore balance, credit, bonus, and correction deals in the daily loss.
input bool   CloseAllMagicOnDailyLock = true; // H3. On the lock, close every symbol with this magic. This terminal only.
input bool   VerifyStopsAfterFill = true;     // M5. Close our position on this symbol if the stop or target is missing.

// ---- Indicator handles ----
int hFast = INVALID_HANDLE;
int hSlow = INVALID_HANDLE;
int hEntry = INVALID_HANDLE;
int hATR = INVALID_HANDLE;
datetime lastBarTime = 0;
bool     armNextBar = false;
datetime loggedBar = 0;
datetime nextCloseAlert = 0;
datetime nextHistoryLog = 0;
bool     entryLockHeld = false;
string   baselineGuardHeld = "";

enum EvalKind
{
   EVAL_RETRY = 0,
   EVAL_DONE  = 1,
   EVAL_SEND  = 2
};

enum DailyState
{
   DAILY_CLEAR = 0,
   DAILY_LOCKED = 1,
   DAILY_NO_BASELINE = 2
};

struct EntrySetup
{
   bool   isBuy;
   double stop;
   double atr;
};

//+------------------------------------------------------------------+
string DailyKey(string suffix)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   return StringFormat("PXBTSTD_CRYPTO_%I64d_%04d%02d%02d_%s",
      (long)AccountInfoInteger(ACCOUNT_LOGIN),
      dt.year, dt.mon, dt.day, suffix);
}

//+------------------------------------------------------------------+
string EntryGuardName()
{
   return StringFormat("PXBTSTD_CRYPTO_%I64d_ENTRY",
      (long)AccountInfoInteger(ACCOUNT_LOGIN));
}

//+------------------------------------------------------------------+
bool Acquire(const string guard, int timeoutMs, int stealAfterSeconds)
{
   GlobalVariableTemp(guard);
   uint start = GetTickCount();
   int budget = (MQLInfoInteger(MQL_TESTER) || timeoutMs <= 0) ? 0 : timeoutMs;

   while(true)
   {
      if(IsStopped())
         return false;

      double stamp = (double)TimeCurrent();
      if(GlobalVariableSetOnCondition(guard, stamp, 0.0))
         return true;

      if(stealAfterSeconds > 0 && GlobalVariableCheck(guard))
      {
         double heldAt = GlobalVariableGet(guard);
         if(heldAt > 0.0 && TimeCurrent() - (datetime)heldAt >= stealAfterSeconds)
         {
            if(GlobalVariableSetOnCondition(guard, stamp, heldAt))
               return true;
         }
      }

      if(budget <= 0 || GetTickCount() - start >= (uint)budget)
         return false;
      Sleep(20);
   }
   return false;
}

//+------------------------------------------------------------------+
void Release(const string guard)
{
   GlobalVariableSet(guard, 0.0);
}

//+------------------------------------------------------------------+
void LogBar(datetime barTime, string message)
{
   if(loggedBar == barTime)
      return;
   loggedBar = barTime;
   Print(message);
}

//+------------------------------------------------------------------+
void AlertClose(string text)
{
   datetime now = TimeCurrent();
   Print(text);
   if(now < nextCloseAlert)
      return;
   nextCloseAlert = now + 60;
   Alert(text);
}

//+------------------------------------------------------------------+
bool TradeAllowed()
{
   return TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
          MQLInfoInteger(MQL_TRADE_ALLOWED);
}

//+------------------------------------------------------------------+
bool IsAllowedSymbol()
{
   string names[];
   int n = StringSplit(AllowedCryptoSymbols, ',', names);
   for(int i=0; i<n; i++)
   {
      StringTrimLeft(names[i]); StringTrimRight(names[i]);
      if(_Symbol == names[i]) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);

   price = MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(price, digits);
}

//+------------------------------------------------------------------+
int VolumeDigits(double step)
{
   for(int i = 0; i <= 8; i++)
      if(MathAbs(step - NormalizeDouble(step, i)) < 1e-8)
         return i;
   return 8;
}

//+------------------------------------------------------------------+
bool HasOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool ReadValue(int handle, int shift, double &value)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);

   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;

   value = buffer[0];
   return value != EMPTY_VALUE;
}

//+------------------------------------------------------------------+
bool IndicatorsReady()
{
   if(!SeriesInfoInteger(_Symbol, PERIOD_H4, SERIES_SYNCHRONIZED))
      return false;
   if(!SeriesInfoInteger(_Symbol, PERIOD_M30, SERIES_SYNCHRONIZED))
      return false;
   if(Bars(_Symbol, PERIOD_H4) < TrendSlowEMA + 2)
      return false;
   if(Bars(_Symbol, PERIOD_M30) < MathMax(EntryEMA, ATRPeriod) + SwingLookback + 2)
      return false;
   if(BarsCalculated(hSlow) < TrendSlowEMA + 2)
      return false;
   if(BarsCalculated(hFast) < TrendFastEMA + 2)
      return false;
   if(BarsCalculated(hEntry) < EntryEMA + 2)
      return false;
   if(BarsCalculated(hATR) < ATRPeriod + 2)
      return false;
   return true;
}

//+------------------------------------------------------------------+
bool TransientRetcode(uint code)
{
   return code == TRADE_RETCODE_REQUOTE ||
          code == TRADE_RETCODE_PRICE_OFF ||
          code == TRADE_RETCODE_PRICE_CHANGED ||
          code == TRADE_RETCODE_TIMEOUT ||
          code == TRADE_RETCODE_CONNECTION ||
          code == TRADE_RETCODE_LOCKED ||
          code == TRADE_RETCODE_FROZEN ||
          code == TRADE_RETCODE_TOO_MANY_REQUESTS ||
          code == TRADE_RETCODE_CLIENT_DISABLES_AT ||
          code == 0;
}

//+------------------------------------------------------------------+
//| Price loss for 1.0 lot, plus the optional per-lot cost.          |
//+------------------------------------------------------------------+
bool LossPerLot(ENUM_ORDER_TYPE orderType, double entry, double stop, double &lossPerLot)
{
   double profitAtStop = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entry, stop, profitAtStop))
   {
      Print("OrderCalcProfit failed. Error: ", GetLastError());
      return false;
   }

   lossPerLot = MathAbs(profitAtStop) + ExtraCostPerLot;
   return true;
}

//+------------------------------------------------------------------+
//| false means the profit calculation failed and the caller should  |
//| retry. volume 0 with true means the trade is deliberately skipped.|
//+------------------------------------------------------------------+
bool CalculateVolume(ENUM_ORDER_TYPE orderType, double entry, double stop, double &volume)
{
   volume = 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * RiskPercent / 100.0;

   if(equity <= 0.0 || riskCash <= 0.0)
      return true;

   double lossPerLot = 0.0;
   if(!LossPerLot(orderType, entry, stop, lossPerLot))
      return false;
   if(lossPerLot <= 0.0)
      return true;

   double rawVolume = riskCash / lossPerLot;
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0 || minVol <= 0.0 || maxVol <= 0.0)
      return true;

   // Round down so calculated risk does not exceed the requested amount.
   double sized = MathFloor(rawVolume / step + 1e-9) * step;

   if(sized > maxVol)
      sized = MathFloor(maxVol / step + 1e-9) * step;

   // Do not force minimum lot size if it would exceed the risk budget.
   if(sized < minVol)
   {
      Print("Trade skipped: minimum volume exceeds risk budget.");
      return true;
   }

   volume = NormalizeDouble(sized, VolumeDigits(step));
   return true;
}

//+------------------------------------------------------------------+
bool ValidStops(double entry, double stop, double target, ENUM_ORDER_TYPE type)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(point <= 0.0)
      return false;

   double minDistance = (double)stopsLevel * point;
   MqlTick liveTick;
   if(!SymbolInfoTick(_Symbol, liveTick) || liveTick.bid <= 0 || liveTick.ask <= 0)
      return false;

   if(type == ORDER_TYPE_BUY)
   {
      if(stop >= entry || target <= entry)
         return false;
      if(liveTick.bid - stop < minDistance || target - liveTick.bid < minDistance)
         return false;
   }
   else
   {
      if(stop <= entry || target >= entry)
         return false;
      if(stop - liveTick.ask < minDistance || liveTick.ask - target < minDistance)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool NonTradeCashSince(datetime from, double &cash)
{
   cash = 0.0;
   if(from <= 0)
      return false;
   if(!HistorySelect(from, TimeCurrent()))
      return false;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;

      ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
      if(dtype == DEAL_TYPE_BALANCE || dtype == DEAL_TYPE_CREDIT ||
         dtype == DEAL_TYPE_BONUS || dtype == DEAL_TYPE_CORRECTION)
         cash += HistoryDealGetDouble(deal, DEAL_PROFIT);
   }
   return true;
}

//+------------------------------------------------------------------+
bool ReadBaseline(double &baseline, datetime &since)
{
   string key = DailyKey("BASE");
   if(!GlobalVariableCheck(key))
      return false;

   baseline = GlobalVariableGet(key);
   if(baseline <= 0.0)
      return false;

   string timeKey = DailyKey("BTIME");
   if(!GlobalVariableCheck(timeKey))
      since = 0;
   else
      since = (datetime)GlobalVariableGet(timeKey);
   return true;
}

//+------------------------------------------------------------------+
//| Publish today's baseline once. A non-positive value is removed.  |
//+------------------------------------------------------------------+
bool EnsureDailyBaseline(double &baseline, datetime &since)
{
   baseline = 0.0;
   since = 0;
   if(DailyLossLimitPercent <= 0.0)
      return false;

   string key = DailyKey("BASE");
   string timeKey = DailyKey("BTIME");
   if(ReadBaseline(baseline, since))
   {
      if(since > 0)
         return true;
   }

   string guard = key + "_G";
   if(!Acquire(guard, 1000, 5))
   {
      if(ReadBaseline(baseline, since) && since > 0)
         return true;
      return false;
   }
   baselineGuardHeld = guard;

   if(GlobalVariableCheck(key) && GlobalVariableGet(key) <= 0.0)
   {
      GlobalVariableDel(key);
      GlobalVariableDel(timeKey);
      Print("Removed a non-positive daily baseline. Entries stay off until equity is positive.");
   }

   if(ReadBaseline(baseline, since) && since == 0)
   {
      datetime stamped = TimeCurrent();
      GlobalVariableSet(timeKey, (double)stamped);
      since = stamped;
      Print("Daily baseline timestamp was missing. Non-trade cashflow adjustment starts now.");
   }

   if(baseline > 0.0 && since > 0)
   {
      baselineGuardHeld = "";
      Release(guard);
      return true;
   }

   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      baselineGuardHeld = "";
      Release(guard);
      return false;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
   {
      baselineGuardHeld = "";
      Release(guard);
      return false;
   }

   datetime now = TimeCurrent();
   GlobalVariableSet(key, equity);
   GlobalVariableSet(timeKey, (double)now);
   baseline = equity;
   since = now;
   Print("Daily equity baseline set to ", DoubleToString(equity, 2),
         " at ", TimeToString(now, TIME_DATE|TIME_SECONDS));
   baselineGuardHeld = "";
   Release(guard);
   return true;
}

//+------------------------------------------------------------------+
DailyState DailyLossState()
{
   if(DailyLossLimitPercent <= 0.0)
      return DAILY_CLEAR;

   string lockKey = DailyKey("LOCK");
   if(GlobalVariableCheck(lockKey))
      return DAILY_LOCKED;

   double baseline = 0.0;
   datetime since = 0;
   if(!EnsureDailyBaseline(baseline, since))
      return DAILY_NO_BASELINE;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double adjusted = equity;
   if(ExcludeNonTradeCashflows)
   {
      double cash = 0.0;
      if(!NonTradeCashSince(since, cash))
      {
         datetime now = TimeCurrent();
         if(now >= nextHistoryLog)
         {
            nextHistoryLog = now + 60;
            Print("Deal history unavailable. Daily loss is not evaluated and entries stay off.");
         }
         return DAILY_NO_BASELINE;
      }
      adjusted = equity - cash;
   }

   if(baseline <= 0.0)
      return DAILY_NO_BASELINE;

   double lossPct = (baseline - adjusted) / baseline * 100.0;
   if(lossPct >= DailyLossLimitPercent)
   {
      GlobalVariableSet(lockKey, 1.0);
      string text = StringFormat("Daily loss limit hit: %.2f%%. New entries locked for this broker-server day.",
                                 lossPct);
      Print(text);
      Alert(text);
      return DAILY_LOCKED;
   }

   return DAILY_CLEAR;
}

//+------------------------------------------------------------------+
bool DirectionAllowed(bool isBuy)
{
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return false;
   if(isBuy && mode == SYMBOL_TRADE_MODE_SHORTONLY)
      return false;
   if(!isBuy && mode == SYMBOL_TRADE_MODE_LONGONLY)
      return false;
   return true;
}

//+------------------------------------------------------------------+
void CloseMagicPositions(bool allSymbols)
{
   if(!TradeAllowed())
   {
      AlertClose("Protective close blocked: algorithmic trading is off. Positions with this magic are not flat.");
      return;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(!allSymbols && PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      if(!trade.PositionClose(ticket))
         AlertClose(StringFormat("Position close failed on %s: %u %s",
                                 symbol,
                                 trade.ResultRetcode(),
                                 trade.ResultRetcodeDescription()));
   }
}

//+------------------------------------------------------------------+
void ProtectNakedPositions()
{
   if(!VerifyStopsAfterFill || !TradeAllowed())
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(PositionGetDouble(POSITION_SL) != 0.0 && PositionGetDouble(POSITION_TP) != 0.0)
         continue;

      AlertClose(StringFormat("Position %I64u on %s has no stop or target. Closing.",
                              ticket, _Symbol));
      if(!trade.PositionClose(ticket))
         AlertClose(StringFormat("Safety close failed: %u %s",
                                 trade.ResultRetcode(),
                                 trade.ResultRetcodeDescription()));
   }
}

//+------------------------------------------------------------------+
bool IsEndOfDay()
{
   if(!EnableEndOfDayClose)
      return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt); // Broker server time

   if(dt.hour > CloseHour)
      return true;

   return (dt.hour == CloseHour && dt.min >= CloseMinute);
}

//+------------------------------------------------------------------+
//| MT5 built-in calendar filter: high-impact events only             |
//+------------------------------------------------------------------+
bool IsNewsWindow()
{
   if(!EnableNewsFilter)
      return false;

   // MT5's live economic calendar is not available in Strategy Tester.
   // News filtering is intentionally bypassed there; see README.
   if(MQLInfoInteger(MQL_TESTER))
      return false;

   datetime now = TimeTradeServer();
   datetime from = now - NewsMinutesAfter * 60;
   datetime to = now + NewsMinutesBefore * 60;

   string currencies[];
   int n = StringSplit(NewsCurrencies, StringGetCharacter(",", 0), currencies);

   if(n <= 0)
   {
      Print("News currency list invalid; blocking new entries.");
      return true;
   }

   bool anyCurrency = false;

   for(int c = 0; c < n; c++)
   {
      StringTrimLeft(currencies[c]);
      StringTrimRight(currencies[c]);

      if(StringLen(currencies[c]) == 0)
         continue;

      anyCurrency = true;
      MqlCalendarValue values[];

      int count = CalendarValueHistory(values, from, to, NULL, currencies[c]);

      if(count < 0)
      {
         Print("Calendar unavailable for ", currencies[c],
               "; blocking entries as a precaution.");
         return true;
      }

      for(int i = 0; i < count; i++)
      {
         MqlCalendarEvent event;
         if(!CalendarEventById(values[i].event_id, event))
         {
            Print("Unable to read calendar event; blocking entries.");
            return true;
         }

         if(event.importance == CALENDAR_IMPORTANCE_HIGH)
         {
            Print("High-impact news window: ", event.name,
                  " (", currencies[c], ")");
            return true;
         }
      }
   }

   if(!anyCurrency)
   {
      Print("No valid news currencies configured; blocking entries.");
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Stop-loss cash of open positions with this magic.                |
//| A position without a stop blocks new risk.                       |
//+------------------------------------------------------------------+
bool OpenStopRisk(double &cash)
{
   cash = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      double sl = PositionGetDouble(POSITION_SL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(sl <= 0.0 || volume <= 0.0 || openPrice <= 0.0)
         return false;

      string symbol = PositionGetString(POSITION_SYMBOL);
      ENUM_ORDER_TYPE orderType =
         ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double profit = 0.0;
      if(!OrderCalcProfit(orderType, symbol, volume, openPrice, sl, profit))
         return false;
      cash += MathAbs(profit) + ExtraCostPerLot * volume;
   }
   return true;
}

//+------------------------------------------------------------------+
bool SendMarket(bool isBuy, double volume, double stop, double target, uint &code)
{
   bool sent = isBuy ? trade.Buy(volume, _Symbol, 0.0, stop, target, "H4-M30 Pullback Buy")
                     : trade.Sell(volume, _Symbol, 0.0, stop, target, "H4-M30 Pullback Sell");
   code = trade.ResultRetcode();
   if(code != TRADE_RETCODE_INVALID_FILL)
      return sent;

   ENUM_ORDER_TYPE_FILLING modes[3];
   modes[0] = ORDER_FILLING_IOC;
   modes[1] = ORDER_FILLING_FOK;
   modes[2] = ORDER_FILLING_RETURN;
   for(int i = 0; i < 3; i++)
   {
      trade.SetTypeFilling(modes[i]);
      sent = isBuy ? trade.Buy(volume, _Symbol, 0.0, stop, target, "H4-M30 Pullback Buy")
                   : trade.Sell(volume, _Symbol, 0.0, stop, target, "H4-M30 Pullback Sell");
      code = trade.ResultRetcode();
      if(code != TRADE_RETCODE_INVALID_FILL)
      {
         Print("Filling mode fallback accepted: ", EnumToString(modes[i]));
         return sent;
      }
   }

   trade.SetTypeFillingBySymbol(_Symbol);
   return false;
}

//+------------------------------------------------------------------+
bool ConfirmFill(bool isBuy, double requested, double stop, double target)
{
   uint code = trade.ResultRetcode();
   if(code != TRADE_RETCODE_DONE && code != TRADE_RETCODE_DONE_PARTIAL)
   {
      Print("Order not opened. Retcode ", code, " ", trade.ResultRetcodeDescription());
      return false;
   }

   Print(isBuy ? "BUY opened" : "SELL opened",
         " | Volume: ", trade.ResultVolume(),
         " | Fill: ", trade.ResultPrice(),
         " | Requested entry: ", requested,
         " | SL: ", stop,
         " | TP: ", target,
         " | Risk: ", RiskPercent, "%",
         " | Target: ", RewardRisk, "R",
         code == TRADE_RETCODE_DONE_PARTIAL ? " | Partial fill" : "");

   if(!VerifyStopsAfterFill)
      return true;

   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      found = true;
      if(PositionGetDouble(POSITION_SL) != 0.0 && PositionGetDouble(POSITION_TP) != 0.0)
         return true;

      AlertClose(StringFormat("Fill on %s has no stop or target. Closing ticket %I64u.",
                              _Symbol, ticket));
      if(!trade.PositionClose(ticket))
         AlertClose(StringFormat("Safety close failed: %u %s",
                                 trade.ResultRetcode(),
                                 trade.ResultRetcodeDescription()));
      return false;
   }

   if(!found)
      Print("Order result did not leave a position on ", _Symbol, ". No second send will be made this bar.");
   return found;
}

//+------------------------------------------------------------------+
//| Closed-bar signal. Prices are applied later, under the lock.     |
//+------------------------------------------------------------------+
EvalKind BuildSetup(datetime barTime, EntrySetup &setup)
{
   if(!EnableNewEntries)
      return EVAL_DONE;

   if(IsNewsWindow())
      return EVAL_DONE;

   if(!TradeAllowed())
      return EVAL_RETRY;

   if(!IndicatorsReady())
   {
      LogBar(barTime, "Entry deferred: H4/M30 history or indicator values are not ready.");
      return EVAL_RETRY;
   }

   if(HasOurPosition())
      return EVAL_DONE;

   // On netting accounts, avoid modifying another EA's or manual position.
   if(PositionSelect(_Symbol))
      return EVAL_DONE;

   double atr = 0.0;
   if(!ReadValue(hATR, 1, atr) || atr <= 0.0)
      return EVAL_RETRY;
   double referenceClose = iClose(_Symbol, PERIOD_M30, 1);
   if(referenceClose <= 0.0)
      return EVAL_RETRY;
   double atrPct = 100.0 * atr / referenceClose;
   if(MinATRPercent > 0.0 && atrPct < MinATRPercent)
      return EVAL_DONE;
   if(MaxATRPercent > 0.0 && atrPct > MaxATRPercent)
      return EVAL_DONE;

   double fastEMA, slowEMA, entryEMA;
   if(!ReadValue(hFast, 1, fastEMA) ||
      !ReadValue(hSlow, 1, slowEMA) ||
      !ReadValue(hEntry, 1, entryEMA))
      return EVAL_RETRY;

   int count = MathMax(SwingLookback + 2, 3);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   if(CopyRates(_Symbol, PERIOD_M30, 1, count, rates) != count)
      return EVAL_RETRY;

   MqlRates signal = rates[0];
   MqlRates prior = rates[1];

   bool upTrend = fastEMA > slowEMA;
   bool downTrend = fastEMA < slowEMA;
   if(RequireH4PriceSide)
   {
      double h4Close = iClose(_Symbol, PERIOD_H4, 1);
      if(h4Close <= 0.0)
         return EVAL_RETRY;
      upTrend = upTrend && h4Close > fastEMA;
      downTrend = downTrend && h4Close < fastEMA;
   }

   // Entry conditions unchanged from v1.30.
   bool bullishPullback =
      signal.low <= entryEMA &&
      signal.close > entryEMA &&
      signal.close > signal.open &&
      signal.close > prior.high;

   bool bearishPullback =
      signal.high >= entryEMA &&
      signal.close < entryEMA &&
      signal.close < signal.open &&
      signal.close < prior.low;

   bool buySignal = AllowBuy && upTrend && bullishPullback;
   bool sellSignal = AllowSell && downTrend && bearishPullback;

   if(!buySignal && !sellSignal)
      return EVAL_DONE;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return EVAL_RETRY;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return EVAL_RETRY;

   if(MaxSpreadPoints > 0 && (tick.ask - tick.bid) / point > MaxSpreadPoints)
      return EVAL_DONE;

   if(MaxSpreadATRRatio > 0.0 && (tick.ask - tick.bid) > MaxSpreadATRRatio * atr)
      return EVAL_DONE;

   double swingLow = rates[0].low;
   double swingHigh = rates[0].high;

   for(int i = 1; i < SwingLookback; i++)
   {
      swingLow = MathMin(swingLow, rates[i].low);
      swingHigh = MathMax(swingHigh, rates[i].high);
   }

   double buffer = MathMax(StopBufferPoints * point,
                           UseATRStopBuffer ? ATRBufferMultiple * atr : 0.0);

   setup.isBuy = buySignal;
   setup.atr = atr;
   setup.stop = setup.isBuy ? NormalizePrice(swingLow - buffer)
                            : NormalizePrice(swingHigh + buffer);
   return EVAL_SEND;
}

//+------------------------------------------------------------------+
EvalKind SendSetup(datetime barTime, EntrySetup &setup)
{
   if(GlobalVariableCheck(DailyKey("LOCK")))
      return EVAL_DONE;

   if(!TradeAllowed())
      return EVAL_RETRY;

   if(!DirectionAllowed(setup.isBuy))
   {
      LogBar(barTime, "Trade skipped: symbol trade mode does not allow this direction.");
      return EVAL_DONE;
   }

   if(HasOurPosition() || PositionSelect(_Symbol))
      return EVAL_DONE;

   if(MaxOpenPositions > 0 && CountOurPositions() >= MaxOpenPositions)
   {
      LogBar(barTime, "Trade skipped: MaxOpenPositions reached.");
      return EVAL_DONE;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return EVAL_RETRY;

   ENUM_ORDER_TYPE type = setup.isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry = setup.isBuy ? tick.ask : tick.bid;
   double stop = setup.stop;
   if(setup.isBuy && stop >= entry)
      return EVAL_DONE;
   if(!setup.isBuy && stop <= entry)
      return EVAL_DONE;

   double target = setup.isBuy ? NormalizePrice(entry + RewardRisk * (entry - stop))
                               : NormalizePrice(entry - RewardRisk * (stop - entry));

   if(MaxStopATRMultiple > 0.0 && MathAbs(entry - stop) > MaxStopATRMultiple * setup.atr)
      return EVAL_DONE;

   if(!ValidStops(entry, stop, target, type))
   {
      LogBar(barTime, "Trade skipped: invalid or too-close stops.");
      return EVAL_DONE;
   }

   double volume = 0.0;
   if(!CalculateVolume(type, entry, stop, volume))
      return EVAL_RETRY;
   if(volume <= 0.0)
      return EVAL_DONE;

   if(MaxTotalRiskPercent > 0.0)
   {
      double openRisk = 0.0;
      if(!OpenStopRisk(openRisk))
      {
         LogBar(barTime, "Trade skipped: an open position has no measurable stop, or profit calculation failed.");
         return EVAL_RETRY;
      }
      double oneLot = 0.0;
      if(!LossPerLot(type, entry, stop, oneLot))
         return EVAL_RETRY;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0 || openRisk + oneLot * volume > equity * MaxTotalRiskPercent / 100.0)
      {
         LogBar(barTime, "Trade skipped: MaxTotalRiskPercent would be exceeded.");
         return EVAL_DONE;
      }
   }

   if(EnableMarginCheck)
   {
      double requiredMargin = 0.0;
      if(!OrderCalcMargin(type, _Symbol, volume, entry, requiredMargin))
         return EVAL_RETRY;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0 || requiredMargin > equity * MaxMarginEquityPercent / 100.0 ||
         requiredMargin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      {
         LogBar(barTime, "Trade skipped: margin cap/free-margin check.");
         return EVAL_DONE;
      }
   }

   if(!ValidStops(entry, stop, target, type))
   {
      LogBar(barTime, "Trade skipped: invalid or too-close stops.");
      return EVAL_DONE;
   }

   uint code = 0;
   bool sent = SendMarket(setup.isBuy, volume, stop, target, code);
   if(!sent || (code != TRADE_RETCODE_DONE && code != TRADE_RETCODE_DONE_PARTIAL))
   {
      if(TransientRetcode(code))
         return EVAL_RETRY;
      LogBar(barTime, StringFormat("Order failed: %u %s", code, trade.ResultRetcodeDescription()));
      return EVAL_DONE;
   }

   if(!ConfirmFill(setup.isBuy, entry, stop, target))
      Print("Order was not kept open with both a stop and a target.");
   return EVAL_DONE;
}

//+------------------------------------------------------------------+
EvalKind CheckSignal(datetime barTime)
{
   EntrySetup setup;
   setup.isBuy = false;
   setup.stop = 0.0;
   setup.atr = 0.0;

   EvalKind built = BuildSetup(barTime, setup);
   if(built != EVAL_SEND)
      return built;

   string guard = EntryGuardName();
   if(!Acquire(guard, 2000, 30))
      return EVAL_RETRY;
   entryLockHeld = true;
   EvalKind sent = SendSetup(barTime, setup);
   Release(guard);
   entryLockHeld = false;
   return sent;
}

//+------------------------------------------------------------------+
void ReleaseIndicators()
{
   if(hFast != INVALID_HANDLE)
   {
      IndicatorRelease(hFast);
      hFast = INVALID_HANDLE;
   }
   if(hSlow != INVALID_HANDLE)
   {
      IndicatorRelease(hSlow);
      hSlow = INVALID_HANDLE;
   }
   if(hEntry != INVALID_HANDLE)
   {
      IndicatorRelease(hEntry);
      hEntry = INVALID_HANDLE;
   }
   if(hATR != INVALID_HANDLE)
   {
      IndicatorRelease(hATR);
      hATR = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
string FillingText(int filling)
{
   string text = "";
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      text += "FOK ";
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      text += "IOC ";
   if(StringLen(text) == 0)
      text = "RETURN ";
   return text;
}

//+------------------------------------------------------------------+
int OnInit()
{
   armNextBar = false;
   loggedBar = 0;
   nextCloseAlert = 0;
   nextHistoryLog = 0;
   entryLockHeld = false;
   baselineGuardHeld = "";

   if(RestrictToPrimeXBTStandardSymbols && !IsAllowedSymbol())
   {
      Print("Symbol not in approved PrimeXBT Standard list: ", _Symbol);
      return INIT_FAILED;
   }
   if(RequirePrimeXBTServerName)
   {
      string server = AccountInfoString(ACCOUNT_SERVER);
      string company = AccountInfoString(ACCOUNT_COMPANY);
      StringToLower(server); StringToLower(company);
      if(StringFind(server,"prime") < 0 && StringFind(company,"prime") < 0 &&
         StringFind(server,"pxbt") < 0 && StringFind(company,"pxbt") < 0)
      {
         Print("PrimeXBT server name could not be verified; refusing to trade.");
         return INIT_FAILED;
      }
   }

   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      Print("Trading is disabled or close-only for symbol: ", _Symbol);
      return INIT_FAILED;
   }
   if(MagicNumber == 0 ||
      DeviationPoints < 0 ||
      RiskPercent <= 0.0 || RiskPercent > 100.0 ||
      RewardRisk <= 0.0 ||
      TrendFastEMA <= 0 || TrendSlowEMA <= TrendFastEMA ||
      EntryEMA <= 0 || SwingLookback < 2 ||
      StopBufferPoints < 0 || MaxSpreadPoints < 0 ||
      DailyLossLimitPercent < 0.0 ||
      NewsMinutesBefore < 0 || NewsMinutesAfter < 0 ||
      CloseHour < 0 || CloseHour > 23 ||
      CloseMinute < 0 || CloseMinute > 59 ||
      ATRPeriod < 1 || ATRBufferMultiple < 0.0 ||
      MinATRPercent < 0.0 || MaxATRPercent < 0.0 ||
      (MaxATRPercent > 0.0 && MaxATRPercent <= MinATRPercent) ||
      MaxSpreadATRRatio < 0.0 || MaxStopATRMultiple < 0.0 ||
      MaxMarginEquityPercent <= 0.0 || MaxMarginEquityPercent > 100.0 ||
      MaxEntryDelaySeconds < 0 || MaxEntryDelaySeconds > 1800 ||
      MaxOpenPositions < 0 ||
      MaxTotalRiskPercent < 0.0 || MaxTotalRiskPercent > 100.0 ||
      ExtraCostPerLot < 0.0)
   {
      Print("Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   hFast = iMA(_Symbol, PERIOD_H4, TrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_H4, TrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEntry = iMA(_Symbol, PERIOD_M30, EntryEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, PERIOD_M30, ATRPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE ||
      hEntry == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles.");
      ReleaseIndicators();
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints((ulong)DeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   Print("Symbol ", _Symbol,
         " mode ", EnumToString((ENUM_SYMBOL_TRADE_MODE)tradeMode),
         " filling ", filling, " ", FillingText(filling),
         " account ", EnumToString((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)),
         " stops ", SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
         " freeze ", SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));

   if(MQLInfoInteger(MQL_TESTER))
      Print("Strategy Tester: one symbol per pass. The cross-chart lock, total-risk cap, and daily baseline are not a portfolio test here. Use every tick based on real ticks. Open-prices mode does not model stop and target fills. The news filter is off in the tester.");

   datetime openBar = iTime(_Symbol, PERIOD_M30, 0);
   if(openBar == 0)
   {
      armNextBar = true;
      lastBarTime = 0;
      Print("M30 time was not available at init. The first bar that appears will be skipped.");
   }
   else
   {
      lastBarTime = openBar;
      Print("Attached during M30 bar ", TimeToString(openBar), ". Waiting for the next bar.");
   }

   if(DailyLossLimitPercent > 0.0)
   {
      double baseline = 0.0;
      datetime since = 0;
      if(GlobalVariableCheck(DailyKey("LOCK")))
         Print("Daily lock is already set for this broker-server day. Entries stay off.");
      else if(!EnsureDailyBaseline(baseline, since))
         Print("Daily baseline is not set. Entries stay off and open positions are not closed.");
   }

   Print("EA 1.40 initialized on ", _Symbol,
         ". Signals use H4 and M30. Server time: ",
         TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(reason == REASON_INITFAILED)
      Print("Deinit after failed init on ", _Symbol, ".");
   if(entryLockHeld)
      Release(EntryGuardName());
   entryLockHeld = false;
   if(StringLen(baselineGuardHeld) > 0)
      Release(baselineGuardHeld);
   baselineGuardHeld = "";
   ReleaseIndicators();
}

//+------------------------------------------------------------------+
void OnTick()
{
   ProtectNakedPositions();

   // Safety management runs on every tick, not just new M30 bars.
   DailyState daily = DailyLossState();
   if(daily == DAILY_LOCKED)
   {
      CloseMagicPositions(CloseAllMagicOnDailyLock);
      return;
   }

   if(daily == DAILY_NO_BASELINE)
      return;

   if(IsEndOfDay())
   {
      CloseMagicPositions(false);
      return;
   }

   // Entry signals are evaluated once the M30 bar is ready, inside the delay window.
   datetime barTime = iTime(_Symbol, PERIOD_M30, 0);
   if(barTime == 0)
      return;

   if(armNextBar)
   {
      lastBarTime = barTime;
      armNextBar = false;
      Print("First M30 bar after a blind init is ", TimeToString(barTime), ". It will not be traded.");
      return;
   }

   if(barTime == lastBarTime)
      return;

   if(TimeCurrent() >= barTime && (int)(TimeCurrent() - barTime) > MaxEntryDelaySeconds)
   {
      Print("Skipping M30 bar ", TimeToString(barTime),
            ": older than MaxEntryDelaySeconds (", MaxEntryDelaySeconds, ").");
      lastBarTime = barTime;
      return;
   }

   if(CheckSignal(barTime) == EVAL_RETRY)
      return;

   lastBarTime = barTime;
}
