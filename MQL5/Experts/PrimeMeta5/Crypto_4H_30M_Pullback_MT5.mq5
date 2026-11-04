#property strict
#property version "1.41"
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

// ---- v1.41 swap, slippage, and algo-off protection (entry rules unchanged) ----
enum ENUM_EA_COMMAND
{
   EA_CMD_RUNNING = 0,   // Running
   EA_CMD_PAUSED  = 1,   // Paused: no new entries, protection stays on
   EA_CMD_FLATTEN = 2    // Flatten: close this magic and take no new entries
};

input ENUM_EA_COMMAND EaCommand = EA_CMD_RUNNING;
input bool   IncludeSwapInRisk = true;             // M2. Add the estimated swap charge over MaxHoldHours to the sizing loss.
input int    MaxHoldHours = 48;                    // M2. Window used to estimate swap. Also the age limit when CloseAfterMaxHold is on.
input bool   CloseAfterMaxHold = false;            // M2. Close this symbol's positions older than MaxHoldHours. Off keeps the original exit.
input double MaxSwapToRiskPercent = 50.0;          // M2. Skip when estimated swap exceeds this percent of the cash risk. 0 disables the skip.
input bool   ExitBeforeTripleSwap = false;         // M2. Close this symbol before a triple-swap charge. Off by default.
input int    SwapChargeHour = 21;                  // M2. Broker-server hour of the daily swap charge. Match the symbol specification.
input int    SwapChargeMinute = 0;                 // M2. Broker-server minute of that charge.
input int    ExitMinutesBeforeSwap = 15;           // M2. Used only when ExitBeforeTripleSwap is on.
input bool   SizeForSlippage = true;               // M2. Size from a worse entry, SlippageAllowancePoints beyond the quote.
input int    SlippageAllowancePoints = 20;         // M2. Extra adverse points assumed in the worst-case entry. 0 disables that allowance.
input int    MaxAdverseSlippagePoints = 20;        // M2. Close the fill when adverse slippage exceeds this many points. 0 disables.
input double MaxAdverseSlippageStopPercent = 25.0; // M2. Close when adverse slippage exceeds this percent of the stop distance. 0 disables.
input bool   TightenStopsNearDailyLimit = true;    // M9. While trading is allowed, pull stops in once the daily loss reaches the threshold below.
input double DailyLimitTightenPercent = 75.0;      // M9. Percent of the daily-loss limit at which stops start tightening.
input bool   AlertOnAlgoOff = true;                // M9. Alert when Algo Trading turns off.
input bool   PushOnAlgoOff = true;                 // M9. SendNotification. Requires a MetaQuotes ID in the terminal.
input bool   EmailOnAlgoOff = false;               // M9. SendMail. Requires the terminal email settings. Off by default.
input bool   WriteHeartbeat = true;                // M9. Refresh a terminal global variable an external watchdog can read.
input bool   WriteHeartbeatFile = true;            // M9. Also write MQL5/Files/PrimeMeta5_<login>.heartbeat.txt
input int    HeartbeatSeconds = 10;                // M9. Minimum seconds between heartbeat updates.

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
int      lastAlgoFlag = -1;
datetime lastHeartbeat = 0;

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
double NormalizePriceSymbol(const string symbol, double price)
{
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);
   price = MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(price, digits);
}

//+------------------------------------------------------------------+
bool AccountValueOf(const string symbol, double amount, const string currency, double price, double &accountValue)
{
   accountValue = 0.0;
   if(amount <= 0.0)
      return true;

   string deposit = AccountInfoString(ACCOUNT_CURRENCY);
   if(currency == deposit)
   {
      accountValue = amount;
      return true;
   }

   double contract = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contract <= 0.0 || price <= 0.0)
      return false;

   string baseCcy = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   string profitCcy = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   double priceDiff = 0.0;
   if(currency == profitCcy)
      priceDiff = amount / contract;
   else if(currency == baseCcy)
      priceDiff = amount * price / contract;
   else
      return false;

   double profit = 0.0;
   if(!OrderCalcProfit(ORDER_TYPE_BUY, symbol, 1.0, price, price + priceDiff, profit))
      return false;
   accountValue = MathAbs(profit);
   return true;
}

//+------------------------------------------------------------------+
double NightRatio(const string symbol, ENUM_DAY_OF_WEEK day)
{
   double sunday = SymbolInfoDouble(symbol, SYMBOL_SWAP_SUNDAY);
   double monday = SymbolInfoDouble(symbol, SYMBOL_SWAP_MONDAY);
   double tuesday = SymbolInfoDouble(symbol, SYMBOL_SWAP_TUESDAY);
   double wednesday = SymbolInfoDouble(symbol, SYMBOL_SWAP_WEDNESDAY);
   double thursday = SymbolInfoDouble(symbol, SYMBOL_SWAP_THURSDAY);
   double friday = SymbolInfoDouble(symbol, SYMBOL_SWAP_FRIDAY);
   double saturday = SymbolInfoDouble(symbol, SYMBOL_SWAP_SATURDAY);
   bool specified = (sunday + monday + tuesday + wednesday + thursday + friday + saturday) > 0.0;

   if(!specified)
   {
      ENUM_DAY_OF_WEEK triple = (ENUM_DAY_OF_WEEK)SymbolInfoInteger(symbol, SYMBOL_SWAP_ROLLOVER3DAYS);
      return (day == triple) ? 3.0 : 1.0;
   }

   double ratio = 0.0;
   switch(day)
   {
      case SUNDAY:    ratio = sunday; break;
      case MONDAY:    ratio = monday; break;
      case TUESDAY:   ratio = tuesday; break;
      case WEDNESDAY: ratio = wednesday; break;
      case THURSDAY:  ratio = thursday; break;
      case FRIDAY:    ratio = friday; break;
      case SATURDAY:  ratio = saturday; break;
      default:        ratio = 0.0; break;
   }
   if(ratio < 0.0)
      ratio = 0.0;
   return ratio;
}

//+------------------------------------------------------------------+
//| Account-currency charge for one adverse swap night, per 1.0 lot. |
//| A credit (positive swap) returns 0. The result is an estimate.    |
//+------------------------------------------------------------------+
bool SwapChargePerLot(const string symbol, bool isBuy, double openPrice, double &charge)
{
   charge = 0.0;
   ENUM_SYMBOL_SWAP_MODE mode = (ENUM_SYMBOL_SWAP_MODE)SymbolInfoInteger(symbol, SYMBOL_SWAP_MODE);
   if(mode == SYMBOL_SWAP_MODE_DISABLED)
      return true;

   double rate = SymbolInfoDouble(symbol, isBuy ? SYMBOL_SWAP_LONG : SYMBOL_SWAP_SHORT);
   if(rate >= 0.0)
      return true;

   double magnitude = MathAbs(rate);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double price = openPrice;
   if(price <= 0.0)
      price = SymbolInfoDouble(symbol, isBuy ? SYMBOL_ASK : SYMBOL_BID);

   if(mode == SYMBOL_SWAP_MODE_POINTS ||
      mode == SYMBOL_SWAP_MODE_REOPEN_CURRENT ||
      mode == SYMBOL_SWAP_MODE_REOPEN_BID)
   {
      if(tickSize <= 0.0)
         return false;
      charge = magnitude * point * tickValue / tickSize;
      return true;
   }

   if(mode == SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT)
   {
      charge = magnitude;
      return true;
   }

   string currency = "";
   double amount = magnitude;
   if(mode == SYMBOL_SWAP_MODE_CURRENCY_PROFIT)
      currency = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   else if(mode == SYMBOL_SWAP_MODE_CURRENCY_SYMBOL)
      currency = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   else if(mode == SYMBOL_SWAP_MODE_CURRENCY_MARGIN)
      currency = SymbolInfoString(symbol, SYMBOL_CURRENCY_MARGIN);
   else if(mode == SYMBOL_SWAP_MODE_INTEREST_CURRENT || mode == SYMBOL_SWAP_MODE_INTEREST_OPEN)
   {
      double contract = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contract <= 0.0 || price <= 0.0)
         return false;
      amount = price * contract * magnitude / 100.0 / 360.0;
      currency = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   }
   else
      return false;

   return AccountValueOf(symbol, amount, currency, price, charge);
}

//+------------------------------------------------------------------+
double SwapUnitsInHold(const string symbol)
{
   if(MaxHoldHours <= 0)
      return 0.0;

   datetime now = TimeCurrent();
   datetime end = now + (datetime)MaxHoldHours * 3600;
   MqlDateTime parts;
   TimeToStruct(now, parts);
   parts.hour = SwapChargeHour;
   parts.min = SwapChargeMinute;
   parts.sec = 0;
   datetime cursor = StructToTime(parts);
   if(cursor <= now)
      cursor += 86400;

   double units = 0.0;
   for(int guard = 0; cursor <= end && guard < 40; guard++)
   {
      MqlDateTime when;
      TimeToStruct(cursor, when);
      units += NightRatio(symbol, (ENUM_DAY_OF_WEEK)when.day_of_week);
      cursor += 86400;
   }
   return units;
}

//+------------------------------------------------------------------+
bool ExpectedSwapPerLot(const string symbol, bool isBuy, double openPrice, double &cost)
{
   cost = 0.0;
   if(!IncludeSwapInRisk || MaxHoldHours <= 0)
      return true;

   double oneNight = 0.0;
   if(!SwapChargePerLot(symbol, isBuy, openPrice, oneNight))
      return false;
   cost = oneNight * SwapUnitsInHold(symbol);
   return true;
}

//+------------------------------------------------------------------+
double WorstEntry(bool isBuy, double entry)
{
   if(!SizeForSlippage || SlippageAllowancePoints <= 0)
      return entry;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slip = SlippageAllowancePoints * point;
   return isBuy ? entry + slip : entry - slip;
}

//+------------------------------------------------------------------+
//| Price loss for 1.0 lot, plus per-lot fee and swap.               |
//+------------------------------------------------------------------+
bool LossPerLot(ENUM_ORDER_TYPE orderType, double entry, double stop, double extraPerLot, double &lossPerLot)
{
   double profitAtStop = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entry, stop, profitAtStop))
   {
      Print("OrderCalcProfit failed. Error: ", GetLastError());
      return false;
   }

   lossPerLot = MathAbs(profitAtStop) + ExtraCostPerLot + MathMax(0.0, extraPerLot);
   return true;
}

//+------------------------------------------------------------------+
//| false means the profit calculation failed and the caller should  |
//| retry. volume 0 with true means the trade is deliberately skipped.|
//+------------------------------------------------------------------+
bool CalculateVolume(ENUM_ORDER_TYPE orderType, double entry, double stop, double extraPerLot, double &volume)
{
   volume = 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * RiskPercent / 100.0;

   if(equity <= 0.0 || riskCash <= 0.0)
      return true;

   double lossPerLot = 0.0;
   if(!LossPerLot(orderType, entry, stop, extraPerLot, lossPerLot))
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

      double swap = 0.0;
      bool isBuy = (orderType == ORDER_TYPE_BUY);
      if(IncludeSwapInRisk && !ExpectedSwapPerLot(symbol, isBuy, openPrice, swap))
         return false;
      cash += MathAbs(profit) + (ExtraCostPerLot + MathMax(0.0, swap)) * volume;
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
      double fill = trade.ResultPrice();
      double adverse = 0.0;
      if(fill > 0.0)
         adverse = isBuy ? (fill - requested) : (requested - fill);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double stopDistance = MathAbs(requested - stop);
      bool tooManyPoints = MaxAdverseSlippagePoints > 0 && point > 0.0 &&
                           adverse > MaxAdverseSlippagePoints * point;
      bool tooMuchOfStop = MaxAdverseSlippageStopPercent > 0.0 && stopDistance > 0.0 &&
                           adverse > stopDistance * MaxAdverseSlippageStopPercent / 100.0;
      if(adverse > 0.0 && (tooManyPoints || tooMuchOfStop))
      {
         AlertClose(StringFormat("Adverse slippage on %s is %.5f (requested %.5f, fill %.5f). Closing ticket %I64u.",
                                 _Symbol, adverse, requested, fill, ticket));
         if(!trade.PositionClose(ticket))
            AlertClose(StringFormat("Slippage close failed: %u %s",
                                    trade.ResultRetcode(),
                                    trade.ResultRetcodeDescription()));
         return false;
      }

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

   double worst = WorstEntry(setup.isBuy, entry);
   if(setup.isBuy && worst <= stop)
   {
      LogBar(barTime, "Trade skipped: slippage allowance consumes the whole stop distance.");
      return EVAL_DONE;
   }
   if(!setup.isBuy && worst >= stop)
   {
      LogBar(barTime, "Trade skipped: slippage allowance consumes the whole stop distance.");
      return EVAL_DONE;
   }

   double swapPerLot = 0.0;
   if(!ExpectedSwapPerLot(_Symbol, setup.isBuy, worst, swapPerLot))
   {
      LogBar(barTime, "Trade skipped: swap could not be converted into account currency.");
      return EVAL_DONE;
   }

   double volume = 0.0;
   if(!CalculateVolume(type, worst, stop, swapPerLot, volume))
      return EVAL_RETRY;
   if(volume <= 0.0)
      return EVAL_DONE;

   double equityNow = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equityNow * RiskPercent / 100.0;
   if(MaxSwapToRiskPercent > 0.0 && riskCash > 0.0 &&
      swapPerLot * volume > riskCash * MaxSwapToRiskPercent / 100.0)
   {
      LogBar(barTime, "Trade skipped: estimated swap is too large a share of the risk budget.");
      return EVAL_DONE;
   }

   if(MaxTotalRiskPercent > 0.0)
   {
      double openRisk = 0.0;
      if(!OpenStopRisk(openRisk))
      {
         LogBar(barTime, "Trade skipped: an open position has no measurable stop, or profit calculation failed.");
         return EVAL_RETRY;
      }
      double oneLot = 0.0;
      if(!LossPerLot(type, worst, stop, swapPerLot, oneLot))
         return EVAL_RETRY;
      double eqRisk = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eqRisk <= 0.0 || openRisk + oneLot * volume > eqRisk * MaxTotalRiskPercent / 100.0)
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
      double eqMargin = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eqMargin <= 0.0 || requiredMargin > eqMargin * MaxMarginEquityPercent / 100.0 ||
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
   lastAlgoFlag = -1;
   lastHeartbeat = 0;

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
      ExtraCostPerLot < 0.0 ||
      MaxHoldHours < 0 || MaxHoldHours > 24 * 30 ||
      MaxSwapToRiskPercent < 0.0 || MaxSwapToRiskPercent > 100.0 ||
      SwapChargeHour < 0 || SwapChargeHour > 23 ||
      SwapChargeMinute < 0 || SwapChargeMinute > 59 ||
      ExitMinutesBeforeSwap < 0 || ExitMinutesBeforeSwap > 12 * 60 ||
      SlippageAllowancePoints < 0 ||
      MaxAdverseSlippagePoints < 0 ||
      MaxAdverseSlippageStopPercent < 0.0 || MaxAdverseSlippageStopPercent > 100.0 ||
      DailyLimitTightenPercent <= 0.0 || DailyLimitTightenPercent > 100.0 ||
      HeartbeatSeconds < 1 || HeartbeatSeconds > 3600)
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

   double buySwap = 0.0;
   double sellSwap = 0.0;
   double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool buySwapOk = ExpectedSwapPerLot(_Symbol, true, refPrice, buySwap);
   bool sellSwapOk = ExpectedSwapPerLot(_Symbol, false, SymbolInfoDouble(_Symbol, SYMBOL_BID), sellSwap);
   Print("Swap mode ", EnumToString((ENUM_SYMBOL_SWAP_MODE)SymbolInfoInteger(_Symbol, SYMBOL_SWAP_MODE)),
         " over ", MaxHoldHours, "h. Estimated charge per lot buy ",
         buySwapOk ? DoubleToString(buySwap, 2) : "unpriced",
         " sell ", sellSwapOk ? DoubleToString(sellSwap, 2) : "unpriced",
         ". No DLL is used. Server-side stops are the protection while Algo Trading is off.");

   Print("EA 1.41 initialized on ", _Symbol,
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
   Comment("");
}

//+------------------------------------------------------------------+
string StateName(int state)
{
   if(state == 1) return "PAUSED";
   if(state == 2) return "LOCKED";
   if(state == 3) return "FLATTEN";
   if(state == 4) return "ALGO_OFF";
   return "RUNNING";
}

//+------------------------------------------------------------------+
int EffectiveState(DailyState daily)
{
   if(!TradeAllowed())
      return 4;
   if(EaCommand == EA_CMD_FLATTEN)
      return 3;
   if(daily == DAILY_LOCKED)
      return 2;
   if(EaCommand == EA_CMD_PAUSED || !EnableNewEntries)
      return 1;
   return 0;
}

//+------------------------------------------------------------------+
void PublishHeartbeat(int state)
{
   if(!WriteHeartbeat && !WriteHeartbeatFile)
      return;

   datetime now = TimeCurrent();
   if(lastHeartbeat != 0 && now - lastHeartbeat < HeartbeatSeconds)
      return;
   lastHeartbeat = now;

   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   string beatKey = StringFormat("PXBTSTD_CRYPTO_%I64d_BEAT", login);
   string stateKey = StringFormat("PXBTSTD_CRYPTO_%I64d_STATE", login);
   if(WriteHeartbeat)
   {
      GlobalVariableSet(beatKey, (double)now);
      GlobalVariableSet(stateKey, (double)state);
   }

   if(!WriteHeartbeatFile || MQLInfoInteger(MQL_TESTER))
      return;

   string name = StringFormat("PrimeMeta5_%I64d.heartbeat.txt", login);
   int handle = FileOpen(name, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      Print("Heartbeat file was not written. Error ", GetLastError());
      return;
   }
   FileWriteString(handle, "time="+TimeToString(now, TIME_DATE|TIME_SECONDS)+"\r\n");
   FileWriteString(handle, "state="+StateName(state)+"\r\n");
   FileWriteString(handle, "algo="+(TradeAllowed() ? "1" : "0")+"\r\n");
   FileWriteString(handle, "symbol="+_Symbol+"\r\n");
   FileWriteString(handle, "equity="+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)+"\r\n");
   FileClose(handle);
}

//+------------------------------------------------------------------+
void NotifyAlgoOff(int state);

void NoteAlgoTransition(int state)
{
   int flag = TradeAllowed() ? 1 : 0;
   if(lastAlgoFlag == -1)
   {
      lastAlgoFlag = flag;
      if(flag == 0)
         NotifyAlgoOff(state);
      return;
   }
   if(lastAlgoFlag == flag)
      return;

   lastAlgoFlag = flag;
   if(flag == 0)
      NotifyAlgoOff(state);
   else
      Print("Algorithmic trading is back on ", _Symbol, ". Protective closes and stop updates resume on this tick.");
}

//+------------------------------------------------------------------+
void NotifyAlgoOff(int state)
{
   string text = StringFormat("PrimeMeta5 %s Algo Trading is OFF. State %s. Server-side stops remain, but this EA cannot close or move positions until the button is on.",
                              _Symbol, StateName(state));
   Print(text);
   if(AlertOnAlgoOff)
      Alert(text);
   if(PushOnAlgoOff && !MQLInfoInteger(MQL_TESTER))
   {
      if(!SendNotification(text))
         Print("Push notification was not sent. Error ", GetLastError(),
               ". Set a MetaQuotes ID in Tools, Options, Notifications.");
   }
   if(EmailOnAlgoOff && !MQLInfoInteger(MQL_TESTER))
   {
      if(!SendMail("PrimeMeta5 algorithmic trading is off", text))
         Print("Email was not sent. Error ", GetLastError(),
               ". Configure Tools, Options, Email.");
   }
}

//+------------------------------------------------------------------+
void ShowState(int state, DailyState daily)
{
   double baseline = 0.0;
   double lossCash = 0.0;
   double lossPct = 0.0;
   string lossText = "n/a";
   datetime since = 0;
   if(ReadBaseline(baseline, since) && baseline > 0.0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double adjusted = equity;
      double cash = 0.0;
      if(!ExcludeNonTradeCashflows || (since > 0 && NonTradeCashSince(since, cash)))
      {
         if(ExcludeNonTradeCashflows)
            adjusted = equity - cash;
         lossCash = baseline - adjusted;
         lossPct = lossCash / baseline * 100.0;
         lossText = StringFormat("%.2f%% of %.2f%%", lossPct, DailyLossLimitPercent);
      }
   }
   else if(daily == DAILY_NO_BASELINE)
      lossText = "baseline not set";

   string body = StringFormat("PrimeMeta5 1.41  %s\nState: %s\nCommand: %s\nAlgo trading: %s\nDaily loss: %s\nHeartbeat: %s\nServer-side stops stay on the broker. This terminal cannot change them while Algo Trading is off.",
                              _Symbol,
                              StateName(state),
                              EnumToString(EaCommand),
                              TradeAllowed() ? "ON" : "OFF",
                              lossText,
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   Comment(body);
}

//+------------------------------------------------------------------+
bool CurrentLossCash(double &baseline, double &lossCash)
{
   baseline = 0.0;
   lossCash = 0.0;
   datetime since = 0;
   if(!ReadBaseline(baseline, since) || baseline <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double adjusted = equity;
   if(ExcludeNonTradeCashflows)
   {
      if(since <= 0)
         return false;
      double cash = 0.0;
      if(!NonTradeCashSince(since, cash))
         return false;
      adjusted = equity - cash;
   }
   lossCash = baseline - adjusted;
   return true;
}

//+------------------------------------------------------------------+
void TightenStops()
{
   if(!TightenStopsNearDailyLimit || DailyLossLimitPercent <= 0.0)
      return;

   double baseline = 0.0;
   double lossCash = 0.0;
   if(!CurrentLossCash(baseline, lossCash))
      return;

   double lossPct = lossCash / baseline * 100.0;
   double trigger = DailyLossLimitPercent * DailyLimitTightenPercent / 100.0;
   if(lossPct < trigger)
      return;

   double budget = baseline * DailyLossLimitPercent / 100.0;
   double remaining = budget - lossCash;
   if(remaining <= 0.0)
      return;

   double openRisk = 0.0;
   if(!OpenStopRisk(openRisk) || openRisk <= remaining)
      return;

   double scale = remaining / openRisk;
   int total = PositionsTotal();
   ulong tickets[];
   ArrayResize(tickets, total);
   int n = 0;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(!CloseAllMagicOnDailyLock && PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      tickets[n++] = ticket;
   }

   for(int k = 0; k < n; k++)
   {
      if(!PositionSelectByTicket(tickets[k]))
         continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      bool isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      if(sl <= 0.0 || openPrice <= 0.0 || volume <= 0.0)
         continue;

      ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double profit = 0.0;
      if(!OrderCalcProfit(orderType, symbol, volume, openPrice, sl, profit))
         continue;
      double currentLoss = MathAbs(profit);
      if(currentLoss <= 0.0)
         continue;

      double targetLoss = currentLoss * scale;
      double oldDist = MathAbs(openPrice - sl);
      if(oldDist <= 0.0)
         continue;
      double newDist = oldDist * (targetLoss / currentLoss);

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick))
         continue;
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist = (double)stopsLevel * point;
      double closest = isBuy ? tick.bid - minDist : tick.ask + minDist;
      double proposed = isBuy ? openPrice - newDist : openPrice + newDist;
      proposed = NormalizePriceSymbol(symbol, proposed);

      double profitClosest = 0.0;
      if(!OrderCalcProfit(orderType, symbol, volume, openPrice, closest, profitClosest))
         continue;
      if(targetLoss + 1e-8 < MathAbs(profitClosest))
      {
         AlertClose(StringFormat("Cannot tighten %s inside the remaining daily budget. Closing ticket %I64u.",
                                 symbol, tickets[k]));
         if(!trade.PositionClose(tickets[k]))
            AlertClose(StringFormat("Budget close failed: %u %s",
                                    trade.ResultRetcode(),
                                    trade.ResultRetcodeDescription()));
         continue;
      }

      if(isBuy)
      {
         if(proposed > closest)
            proposed = NormalizePriceSymbol(symbol, closest);
         if(proposed <= sl)
            continue;
      }
      else
      {
         if(proposed < closest)
            proposed = NormalizePriceSymbol(symbol, closest);
         if(proposed >= sl)
            continue;
      }

      if(MathAbs(proposed - sl) < point)
         continue;
      if(!trade.PositionModify(tickets[k], proposed, tp))
         Print("Stop tighten failed on ", symbol, ": ", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
bool InTripleSwapWindow()
{
   if(!ExitBeforeTripleSwap || ExitMinutesBeforeSwap <= 0)
      return false;

   datetime now = TimeCurrent();
   MqlDateTime parts;
   TimeToStruct(now, parts);
   parts.hour = SwapChargeHour;
   parts.min = SwapChargeMinute;
   parts.sec = 0;
   datetime charge = StructToTime(parts);
   if(now >= charge)
      return false;
   if((charge - now) > (datetime)ExitMinutesBeforeSwap * 60)
      return false;

   double ratio = NightRatio(_Symbol, (ENUM_DAY_OF_WEEK)parts.day_of_week);
   return (ratio >= 2.5);
}

//+------------------------------------------------------------------+
void CloseForHoldAndSwap()
{
   bool triple = InTripleSwapWindow();
   if(!triple && !CloseAfterMaxHold)
      return;

   datetime oldest = 0;
   if(CloseAfterMaxHold && MaxHoldHours > 0)
      oldest = TimeCurrent() - (datetime)MaxHoldHours * 3600;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      bool aged = (CloseAfterMaxHold && MaxHoldHours > 0 &&
                   (datetime)PositionGetInteger(POSITION_TIME) <= oldest);
      if(!triple && !aged)
         continue;

      string why = triple ? "triple-swap window" : "max hold time";
      Print("Closing ", _Symbol, " ticket ", ticket, " for ", why, ".");
      if(!trade.PositionClose(ticket))
         AlertClose(StringFormat("Scheduled close failed: %u %s",
                                 trade.ResultRetcode(),
                                 trade.ResultRetcodeDescription()));
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   DailyState daily = DailyLossState();
   int state = EffectiveState(daily);
   NoteAlgoTransition(state);
   ShowState(state, daily);
   PublishHeartbeat(state);

   // No trade request can succeed while the terminal button is off.
   // Existing broker-side stops remain. Pending protection runs on the next allowed tick.
   if(!TradeAllowed())
      return;

   if(EaCommand == EA_CMD_FLATTEN)
   {
      CloseMagicPositions(true);
      return;
   }

   ProtectNakedPositions();
   TightenStops();
   CloseForHoldAndSwap();

   // Safety management runs on every tick, not just new M30 bars.
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

   if(EaCommand == EA_CMD_PAUSED || !EnableNewEntries)
      return;

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
