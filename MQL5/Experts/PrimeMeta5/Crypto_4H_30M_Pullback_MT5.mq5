#property strict
#property version "1.30"
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

// ---- Indicator handles ----
int hFast = INVALID_HANDLE;
int hSlow = INVALID_HANDLE;
int hEntry = INVALID_HANDLE;
int hATR = INVALID_HANDLE;
datetime lastBarTime = 0;

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
//| Calculate volume from estimated cash loss at the stop             |
//+------------------------------------------------------------------+
double CalculateVolume(ENUM_ORDER_TYPE orderType, double entry, double stop)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * RiskPercent / 100.0;

   if(equity <= 0.0 || riskCash <= 0.0)
      return 0.0;

   double profitAtStop = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entry, stop, profitAtStop))
   {
      Print("OrderCalcProfit failed. Error: ", GetLastError());
      return 0.0;
   }

   double lossPerLot = MathAbs(profitAtStop);
   if(lossPerLot <= 0.0)
      return 0.0;

   double rawVolume = riskCash / lossPerLot;
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0 || minVol <= 0.0 || maxVol <= 0.0)
      return 0.0;

   // Round down so calculated risk does not exceed the requested amount.
   double volume = MathFloor(rawVolume / step + 1e-9) * step;

   if(volume > maxVol)
      volume = MathFloor(maxVol / step + 1e-9) * step;

   // Do not force minimum lot size if it would exceed the risk budget.
   if(volume < minVol)
   {
      Print("Trade skipped: minimum volume exceeds risk budget.");
      return 0.0;
   }

   return NormalizeDouble(volume, VolumeDigits(step));
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
//| Persistent daily baseline and daily lock                          |
//+------------------------------------------------------------------+
string DailyKey(string suffix)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   return StringFormat("PXBTSTD_CRYPTO_%I64d_%04d%02d%02d_%s",
      AccountInfoInteger(ACCOUNT_LOGIN),
      dt.year, dt.mon, dt.day, suffix);
}

double GetDailyBaseline()
{
   string key = DailyKey("BASE");

   if(!GlobalVariableCheck(key))
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(key, equity);
      Print("Daily equity baseline set to ", equity);
      return equity;
   }

   return GlobalVariableGet(key);
}

bool IsDailyLossLimitHit()
{
   if(DailyLossLimitPercent <= 0.0)
      return false;

   double baseline = GetDailyBaseline();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(baseline <= 0.0)
      return true;

   string lockKey = DailyKey("LOCK");
   if(GlobalVariableCheck(lockKey))
      return true;

   double lossPct = (baseline - equity) / baseline * 100.0;

   if(lossPct >= DailyLossLimitPercent)
   {
      GlobalVariableSet(lockKey, 1.0);
      Print("Daily loss limit hit: ", DoubleToString(lossPct, 2),
            "%. New entries locked for this broker-server day.");
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Close this EA's positions on this symbol                          |
//+------------------------------------------------------------------+
void CloseOurPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
         Print("Position close failed: ", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
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
void CheckSignal()
{
   if(!EnableNewEntries)
      return;

   if(IsDailyLossLimitHit() || IsEndOfDay() || IsNewsWindow())
      return;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   if(HasOurPosition())
      return;

   // On netting accounts, avoid modifying another EA's or manual position.
   if(PositionSelect(_Symbol)) return;

   if(MaxSpreadPoints > 0)
   {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
         return;

      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(point <= 0.0)
         return;

      if((tick.ask - tick.bid) / point > MaxSpreadPoints)
         return;
   }

   // Closed H4/M30 values only.
   double atr = 0.0;
   if(!ReadValue(hATR, 1, atr) || atr <= 0.0) return;
   double referenceClose = iClose(_Symbol, PERIOD_M30, 1);
   if(referenceClose <= 0.0) return;
   double atrPct = 100.0 * atr / referenceClose;
   if(MinATRPercent > 0.0 && atrPct < MinATRPercent) return;
   if(MaxATRPercent > 0.0 && atrPct > MaxATRPercent) return;

   double fastEMA, slowEMA, entryEMA;
   if(!ReadValue(hFast, 1, fastEMA) ||
      !ReadValue(hSlow, 1, slowEMA) ||
      !ReadValue(hEntry, 1, entryEMA))
      return;

   int count = MathMax(SwingLookback + 2, 3);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   if(CopyRates(_Symbol, PERIOD_M30, 1, count, rates) != count)
      return;

   MqlRates signal = rates[0];
   MqlRates prior = rates[1];

   bool upTrend = fastEMA > slowEMA;
   bool downTrend = fastEMA < slowEMA;
   if(RequireH4PriceSide)
   {
      double h4Close = iClose(_Symbol, PERIOD_H4, 1);
      upTrend = upTrend && h4Close > fastEMA;
      downTrend = downTrend && h4Close < fastEMA;
   }

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
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return;

   double swingLow = rates[0].low;
   double swingHigh = rates[0].high;

   for(int i = 1; i < SwingLookback; i++)
   {
      swingLow = MathMin(swingLow, rates[i].low);
      swingHigh = MathMax(swingHigh, rates[i].high);
   }

   if(MaxSpreadATRRatio > 0.0 && (tick.ask - tick.bid) > MaxSpreadATRRatio * atr)
      return;

   double buffer = MathMax(StopBufferPoints * point,
                           UseATRStopBuffer ? ATRBufferMultiple * atr : 0.0);
   double entry, stop, target;
   ENUM_ORDER_TYPE type;
   bool isBuy = buySignal;

   if(isBuy)
   {
      type = ORDER_TYPE_BUY;
      entry = tick.ask;
      stop = NormalizePrice(swingLow - buffer);

      if(stop >= entry)
         return;

      target = NormalizePrice(entry + RewardRisk * (entry - stop));
   }
   else
   {
      type = ORDER_TYPE_SELL;
      entry = tick.bid;
      stop = NormalizePrice(swingHigh + buffer);

      if(stop <= entry)
         return;

      target = NormalizePrice(entry - RewardRisk * (stop - entry));
   }

   if(MaxStopATRMultiple > 0.0 && MathAbs(entry - stop) > MaxStopATRMultiple * atr)
      return;

   if(!ValidStops(entry, stop, target, type))
   {
      Print("Trade skipped: invalid or too-close stops.");
      return;
   }

   double volume = CalculateVolume(type, entry, stop);
   if(volume <= 0.0)
      return;

   if(EnableMarginCheck)
   {
      double requiredMargin = 0.0;
      if(!OrderCalcMargin(type, _Symbol, volume, entry, requiredMargin)) return;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0 || requiredMargin > equity * MaxMarginEquityPercent / 100.0 ||
         requiredMargin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      {
         Print("Trade skipped: margin cap/free-margin check.");
         return;
      }
   }

   // Revalidate stop and take profit against latest executable quotes.
   if(!ValidStops(entry, stop, target, type)) return;

   bool sent = false;

   if(isBuy)
      sent = trade.Buy(volume, _Symbol, 0.0, stop, target, "H4-M30 Pullback Buy");
   else
      sent = trade.Sell(volume, _Symbol, 0.0, stop, target, "H4-M30 Pullback Sell");

   uint retcode = trade.ResultRetcode();

   if(!sent ||
      (retcode != TRADE_RETCODE_DONE &&
       retcode != TRADE_RETCODE_DONE_PARTIAL &&
       retcode != TRADE_RETCODE_PLACED))
   {
      Print("Order failed: ", retcode, " ", trade.ResultRetcodeDescription());
      return;
   }

   Print(isBuy ? "BUY opened" : "SELL opened",
         " | Volume: ", volume,
         " | Requested entry: ", entry,
         " | SL: ", stop,
         " | TP: ", target,
         " | Risk: ", RiskPercent, "%",
         " | Target: ", RewardRisk, "R");
}

//+------------------------------------------------------------------+
int OnInit()
{
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
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Trading disabled for symbol: ", _Symbol);
      return INIT_FAILED;
   }
   if(RiskPercent <= 0.0 || RiskPercent > 100.0 ||
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
      MaxMarginEquityPercent <= 0.0 || MaxMarginEquityPercent > 100.0)
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
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   lastBarTime = iTime(_Symbol, PERIOD_M30, 0);

   // Initialize the daily baseline when EA first starts that day.
   GetDailyBaseline();

   Print("EA initialized on ", _Symbol,
         ". Signals use H4 and M30. Server time: ",
         TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFast != INVALID_HANDLE)
      IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE)
      IndicatorRelease(hSlow);
   if(hEntry != INVALID_HANDLE)
      IndicatorRelease(hEntry);
   if(hATR != INVALID_HANDLE)
      IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Safety management runs on every tick, not just new M30 bars.
   if(IsDailyLossLimitHit())
   {
      CloseOurPositions();
      return;
   }

   if(IsEndOfDay())
   {
      CloseOurPositions();
      return;
   }

   // Entry signals are evaluated once per new M30 candle.
   datetime barTime = iTime(_Symbol, PERIOD_M30, 0);
   if(barTime == 0 || barTime == lastBarTime)
      return;

   lastBarTime = barTime;
   CheckSignal();
}
