#property strict
#property version   "1.00"
#property description "Directional Pullback EA (MT5): discretionary direction + M5 pullback execution"

#include <Trade/Trade.mqh>
CTrade trade;

enum DirectionEnum { LongOnly=0, ShortOnly=1, Both=2 };

input int      MagicNumber                = 52501;
input double   BaseRiskPercent            = 1.0;
input DirectionEnum DirectionMode          = LongOnly;
input int      FastEMAPeriod              = 20;
input int      SlowEMAPeriod              = 50;
input int      RSIPeriod                  = 14;
input double   RSIZoneLow                 = 40.0;
input double   RSIZoneHigh                = 50.0;
input int      BreakoutLookbackBars       = 20;
input int      FractalLeft                = 2;
input int      FractalRight               = 2;
input int      StructureLookbackBars      = 200;
input int      SlBufferPoints             = 2;
input int      MaxSpreadPoints            = 120;
input int      SessionStartHour           = 0;
input int      SessionEndHour             = 23;
input string   AllowedSymbolsCSV          = "XAUUSD,EURUSD,GBPUSD,AUDUSD,US100,USOIL,BTCUSD";
input double   DDLevel1Pct                = 5.0;
input double   DDLevel2Pct                = 10.0;
input double   DDLevel3Pct                = 15.0;
input double   DDCoeff1                   = 1.0;
input double   DDCoeff2                   = 0.7;
input double   DDCoeff3                   = 0.5;
input double   DDCoeff4                   = 0.2;

string PEAK_BALANCE_KEY;
datetime g_lastBarTime = 0;


string ToUpperCopy(string v)
{
   StringToUpper(v);
   return v;
}

string TrimCopy(string v)
{
   while(StringLen(v) > 0 && StringGetCharacter(v, 0) <= 32)
      v = StringSubstr(v, 1);
   while(StringLen(v) > 0 && StringGetCharacter(v, StringLen(v)-1) <= 32)
      v = StringSubstr(v, 0, StringLen(v)-1);
   return v;
}

int hEMA20, hEMA50, hRSI;

bool IsNewBar()
{
   datetime t[];
   if(CopyTime(_Symbol, PERIOD_M5, 0, 1, t) < 1) return false;
   if(t[0] != g_lastBarTime)
   {
      g_lastBarTime = t[0];
      return true;
   }
   return false;
}

bool IsAllowedSymbol()
{
   string s = ToUpperCopy(_Symbol);
   string csv = ToUpperCopy(AllowedSymbolsCSV);
   string parts[];
   int n = StringSplit(csv, ',', parts);
   for(int i=0;i<n;i++)
   {
      string p = parts[i];
      p = TrimCopy(p);
      if(s == p) return true;
   }
   return false;
}

bool InSession()
{
   if(SessionStartHour == SessionEndHour) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(SessionStartHour < SessionEndHour) return (h >= SessionStartHour && h < SessionEndHour);
   return (h >= SessionStartHour || h < SessionEndHour);
}

void UpdatePeakBalance()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!GlobalVariableCheck(PEAK_BALANCE_KEY))
   {
      GlobalVariableSet(PEAK_BALANCE_KEY, bal);
      return;
   }
   double peak = GlobalVariableGet(PEAK_BALANCE_KEY);
   if(bal > peak) GlobalVariableSet(PEAK_BALANCE_KEY, bal);
}

double GetDDCoeff()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double peak = GlobalVariableCheck(PEAK_BALANCE_KEY) ? GlobalVariableGet(PEAK_BALANCE_KEY) : bal;
   if(peak <= 0.0) return DDCoeff1;
   double ddPct = (peak - bal) / peak * 100.0;
   if(ddPct < DDLevel1Pct) return DDCoeff1;
   if(ddPct < DDLevel2Pct) return DDCoeff2;
   if(ddPct < DDLevel3Pct) return DDCoeff3;
   return DDCoeff4;
}

bool HasOpenPositionForSymbol()
{
   if(!PositionSelect(_Symbol)) return false;
   if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) return false;
   return true;
}

bool TouchesEMABand(const MqlRates &bar, double emaFast, double emaSlow)
{
   double top = MathMax(emaFast, emaSlow);
   double bot = MathMin(emaFast, emaSlow);
   return (bar.low <= top && bar.high >= bot);
}

bool IsFractalLow(MqlRates &rates[], int idx)
{
   double c = rates[idx].low;
   for(int i=1;i<=FractalLeft;i++) if(rates[idx+i].low <= c) return false;
   for(int j=1;j<=FractalRight;j++) if(rates[idx-j].low <= c) return false;
   return true;
}

bool IsFractalHigh(MqlRates &rates[], int idx)
{
   double c = rates[idx].high;
   for(int i=1;i<=FractalLeft;i++) if(rates[idx+i].high >= c) return false;
   for(int j=1;j<=FractalRight;j++) if(rates[idx-j].high >= c) return false;
   return true;
}

bool FindLatestFractalLow(double &price)
{
   MqlRates rates[];
   int need = MathMax(StructureLookbackBars + FractalLeft + FractalRight + 5, 100);
   int got = CopyRates(_Symbol, PERIOD_M5, 0, need, rates);
   if(got <= FractalLeft + FractalRight + 5) return false;
   ArraySetAsSeries(rates, true);

   for(int idx=FractalRight+1; idx<MathMin(got-FractalLeft, StructureLookbackBars); idx++)
   {
      if(IsFractalLow(rates, idx))
      {
         price = rates[idx].low;
         return true;
      }
   }
   return false;
}

bool FindLatestFractalHigh(double &price)
{
   MqlRates rates[];
   int need = MathMax(StructureLookbackBars + FractalLeft + FractalRight + 5, 100);
   int got = CopyRates(_Symbol, PERIOD_M5, 0, need, rates);
   if(got <= FractalLeft + FractalRight + 5) return false;
   ArraySetAsSeries(rates, true);

   for(int idx=FractalRight+1; idx<MathMin(got-FractalLeft, StructureLookbackBars); idx++)
   {
      if(IsFractalHigh(rates, idx))
      {
         price = rates[idx].high;
         return true;
      }
   }
   return false;
}

double CalcLotByRisk(double slDistancePrice)
{
   if(slDistancePrice <= 0.0) return 0.0;

   double coeff = GetDDCoeff();
   double riskPct = BaseRiskPercent * coeff;
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = _Point;
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;

   double points = slDistancePrice / point;
   double valuePerPointPerLot = tickValue * (point / tickSize);
   double lossPerLot = points * valuePerPointPerLot;
   if(lossPerLot <= 0.0) return 0.0;

   double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lot = riskMoney / lossPerLot;
   lot = MathMax(volMin, MathMin(volMax, lot));
   lot = MathFloor(lot / volStep) * volStep;
   return NormalizeDouble(lot, 2);
}

bool BuySignal()
{
   MqlRates bars[];
   if(CopyRates(_Symbol, PERIOD_M5, 0, BreakoutLookbackBars + 5, bars) < BreakoutLookbackBars + 3) return false;
   ArraySetAsSeries(bars, true);

   double ema20[3], ema50[3], rsi[4];
   if(CopyBuffer(hEMA20, 0, 0, 3, ema20) < 3) return false;
   if(CopyBuffer(hEMA50, 0, 0, 3, ema50) < 3) return false;
   if(CopyBuffer(hRSI, 0, 0, 4, rsi) < 4) return false;
   ArraySetAsSeries(ema20, true); ArraySetAsSeries(ema50, true); ArraySetAsSeries(rsi, true);

   if(!TouchesEMABand(bars[1], ema20[1], ema50[1])) return false;
   if(!(rsi[1] >= RSIZoneLow && rsi[1] <= RSIZoneHigh && rsi[1] > rsi[2])) return false;

   double hh = -DBL_MAX;
   for(int i=2;i<2+BreakoutLookbackBars;i++) hh = MathMax(hh, bars[i].high);
   return (bars[1].close > hh);
}

bool SellSignal()
{
   MqlRates bars[];
   if(CopyRates(_Symbol, PERIOD_M5, 0, BreakoutLookbackBars + 5, bars) < BreakoutLookbackBars + 3) return false;
   ArraySetAsSeries(bars, true);

   double ema20[3], ema50[3], rsi[4];
   if(CopyBuffer(hEMA20, 0, 0, 3, ema20) < 3) return false;
   if(CopyBuffer(hEMA50, 0, 0, 3, ema50) < 3) return false;
   if(CopyBuffer(hRSI, 0, 0, 4, rsi) < 4) return false;
   ArraySetAsSeries(ema20, true); ArraySetAsSeries(ema50, true); ArraySetAsSeries(rsi, true);

   if(!TouchesEMABand(bars[1], ema20[1], ema50[1])) return false;
   if(!(rsi[1] >= (100.0-RSIZoneHigh) && rsi[1] <= (100.0-RSIZoneLow) && rsi[1] < rsi[2])) return false;

   double ll = DBL_MAX;
   for(int i=2;i<2+BreakoutLookbackBars;i++) ll = MathMin(ll, bars[i].low);
   return (bars[1].close < ll);
}

void ManagePosition()
{
   if(!PositionSelect(_Symbol)) return;
   if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) return;

   long type = PositionGetInteger(POSITION_TYPE);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);

   MqlRates bars[];
   if(CopyRates(_Symbol, PERIOD_M5, 0, 3, bars) < 3) return;
   ArraySetAsSeries(bars, true);

   double ema20[3];
   if(CopyBuffer(hEMA20, 0, 0, 3, ema20) < 3) return;
   ArraySetAsSeries(ema20, true);

   if(type == POSITION_TYPE_BUY)
   {
      if(bars[1].close < ema20[1] && bars[2].close >= ema20[2])
      {
         trade.PositionClose(_Symbol);
         return;
      }

      double fract;
      if(FindLatestFractalLow(fract))
      {
         double newSL = fract - SlBufferPoints * _Point;
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(newSL > sl && newSL < bid)
            trade.PositionModify(_Symbol, NormalizeDouble(newSL, _Digits), tp);
      }
   }
   else if(type == POSITION_TYPE_SELL)
   {
      if(bars[1].close > ema20[1] && bars[2].close <= ema20[2])
      {
         trade.PositionClose(_Symbol);
         return;
      }

      double fract;
      if(FindLatestFractalHigh(fract))
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double spreadPts = (ask - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
         double newSL = fract + (spreadPts + SlBufferPoints) * _Point;
         if((sl == 0.0 || newSL < sl) && newSL > ask)
            trade.PositionModify(_Symbol, NormalizeDouble(newSL, _Digits), tp);
      }
   }
}

int OnInit()
{
   if(_Period != PERIOD_M5) return(INIT_FAILED);

   trade.SetExpertMagicNumber(MagicNumber);
   PEAK_BALANCE_KEY = "DirectionalPullbackEA_peak_" + (string)AccountInfoInteger(ACCOUNT_LOGIN);
   UpdatePeakBalance();

   hEMA20 = iMA(_Symbol, PERIOD_M5, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50 = iMA(_Symbol, PERIOD_M5, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hRSI   = iRSI(_Symbol, PERIOD_M5, RSIPeriod, PRICE_CLOSE);

   if(hEMA20==INVALID_HANDLE || hEMA50==INVALID_HANDLE || hRSI==INVALID_HANDLE)
      return(INIT_FAILED);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(hEMA20!=INVALID_HANDLE) IndicatorRelease(hEMA20);
   if(hEMA50!=INVALID_HANDLE) IndicatorRelease(hEMA50);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
}

void OnTick()
{
   if(_Period != PERIOD_M5) return;
   if(!IsAllowedSymbol()) return;
   if(!InSession()) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPts = (ask - bid) / _Point;
   if(spreadPts > MaxSpreadPoints) return;

   UpdatePeakBalance();

   if(IsNewBar()) ManagePosition();
   if(HasOpenPositionForSymbol()) return;

   if(DirectionMode == LongOnly || DirectionMode == Both)
   {
      if(BuySignal())
      {
         double fract;
         if(!FindLatestFractalLow(fract)) return;
         double sl = fract - SlBufferPoints * _Point;
         double lot = CalcLotByRisk(ask - sl);
         if(lot > 0.0 && sl < ask)
            trade.Buy(lot, _Symbol, 0.0, NormalizeDouble(sl, _Digits), 0.0, "DirPullbackEA");
      }
   }

   if(DirectionMode == ShortOnly || DirectionMode == Both)
   {
      if(SellSignal())
      {
         double fract;
         if(!FindLatestFractalHigh(fract)) return;
         double sl = fract + (spreadPts + SlBufferPoints) * _Point;
         double lot = CalcLotByRisk(sl - bid);
         if(lot > 0.0 && sl > bid)
            trade.Sell(lot, _Symbol, 0.0, NormalizeDouble(sl, _Digits), 0.0, "DirPullbackEA");
      }
   }
}
