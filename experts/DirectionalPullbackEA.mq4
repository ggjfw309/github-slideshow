#property strict
#property description "Directional Pullback EA (MT4): discretionary direction + M5 pullback execution"

extern int    MagicNumber                = 52001;
extern double BaseRiskPercent            = 1.0;
extern int    DirectionMode              = 0;      // 0=LongOnly,1=ShortOnly,2=Both
extern int    FastEMAPeriod              = 20;
extern int    SlowEMAPeriod              = 50;
extern int    RSIPeriod                  = 14;
extern double RSIZoneLow                 = 40.0;
extern double RSIZoneHigh                = 50.0;
extern int    BreakoutLookbackBars       = 20;
extern int    FractalLeft                = 2;
extern int    FractalRight               = 2;
extern int    StructureLookbackBars      = 200;
extern int    SlBufferPoints             = 2;
extern int    MaxSpreadPoints            = 120;
extern int    SessionStartHour           = 0;      // server time hour
extern int    SessionEndHour             = 23;     // server time hour
extern string AllowedSymbolsCSV          = "XAUUSD,EURUSD,GBPUSD,AUDUSD,US100,USOIL,BTCUSD";
extern double DDLevel1Pct                = 5.0;
extern double DDLevel2Pct                = 10.0;
extern double DDLevel3Pct                = 15.0;
extern double DDCoeff1                   = 1.0;
extern double DDCoeff2                   = 0.7;
extern double DDCoeff3                   = 0.5;
extern double DDCoeff4                   = 0.2;

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


bool IsNewBar()
{
   datetime t = iTime(Symbol(), PERIOD_M5, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

bool IsAllowedSymbol()
{
   string s = ToUpperCopy(Symbol());
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
   int h = TimeHour(TimeCurrent());
   if(SessionStartHour < SessionEndHour)
      return (h >= SessionStartHour && h < SessionEndHour);
   return (h >= SessionStartHour || h < SessionEndHour);
}

bool HasOpenPositionForSymbol()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber && (OrderType()==OP_BUY || OrderType()==OP_SELL))
         return true;
   }
   return false;
}

void UpdatePeakBalance()
{
   double bal = AccountBalance();
   if(!GlobalVariableCheck(PEAK_BALANCE_KEY))
   {
      GlobalVariableSet(PEAK_BALANCE_KEY, bal);
      return;
   }
   double peak = GlobalVariableGet(PEAK_BALANCE_KEY);
   if(bal > peak)
      GlobalVariableSet(PEAK_BALANCE_KEY, bal);
}

double GetDDCoeff()
{
   double bal = AccountBalance();
   double peak = GlobalVariableCheck(PEAK_BALANCE_KEY) ? GlobalVariableGet(PEAK_BALANCE_KEY) : bal;
   if(peak <= 0.0) return DDCoeff1;
   double ddPct = (peak - bal) / peak * 100.0;
   if(ddPct < DDLevel1Pct) return DDCoeff1;
   if(ddPct < DDLevel2Pct) return DDCoeff2;
   if(ddPct < DDLevel3Pct) return DDCoeff3;
   return DDCoeff4;
}

bool TouchesEMABand(int shift, double emaFast, double emaSlow)
{
   double top = MathMax(emaFast, emaSlow);
   double bot = MathMin(emaFast, emaSlow);
   double hi = iHigh(Symbol(), PERIOD_M5, shift);
   double lo = iLow(Symbol(), PERIOD_M5, shift);
   return (lo <= top && hi >= bot);
}

bool IsFractalLow(int shift)
{
   if(shift <= FractalRight) return false;
   double center = iLow(Symbol(), PERIOD_M5, shift);
   for(int i=1;i<=FractalLeft;i++) if(iLow(Symbol(), PERIOD_M5, shift+i) <= center) return false;
   for(int j=1;j<=FractalRight;j++) if(iLow(Symbol(), PERIOD_M5, shift-j) <= center) return false;
   return true;
}

bool IsFractalHigh(int shift)
{
   if(shift <= FractalRight) return false;
   double center = iHigh(Symbol(), PERIOD_M5, shift);
   for(int i=1;i<=FractalLeft;i++) if(iHigh(Symbol(), PERIOD_M5, shift+i) >= center) return false;
   for(int j=1;j<=FractalRight;j++) if(iHigh(Symbol(), PERIOD_M5, shift-j) >= center) return false;
   return true;
}

bool FindLatestFractalLow(double &price)
{
   int start = FractalRight + 1;
   int end = MathMin(StructureLookbackBars, Bars-2-FractalLeft);
   for(int s=start; s<=end; s++)
   {
      if(IsFractalLow(s))
      {
         price = iLow(Symbol(), PERIOD_M5, s);
         return true;
      }
   }
   return false;
}

bool FindLatestFractalHigh(double &price)
{
   int start = FractalRight + 1;
   int end = MathMin(StructureLookbackBars, Bars-2-FractalLeft);
   for(int s=start; s<=end; s++)
   {
      if(IsFractalHigh(s))
      {
         price = iHigh(Symbol(), PERIOD_M5, s);
         return true;
      }
   }
   return false;
}

double HighestHigh(int fromShift, int count)
{
   double v = -DBL_MAX;
   for(int i=fromShift; i<fromShift+count; i++) v = MathMax(v, iHigh(Symbol(), PERIOD_M5, i));
   return v;
}

double LowestLow(int fromShift, int count)
{
   double v = DBL_MAX;
   for(int i=fromShift; i<fromShift+count; i++) v = MathMin(v, iLow(Symbol(), PERIOD_M5, i));
   return v;
}

double CalcLotByRisk(double slDistancePrice)
{
   if(slDistancePrice <= 0.0) return 0.0;
   double coeff = GetDDCoeff();
   double effectiveRiskPct = BaseRiskPercent * coeff;
   double riskMoney = AccountBalance() * effectiveRiskPct / 100.0;

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;

   double points = slDistancePrice / Point;
   double valuePerPointPerLot = tickValue * (Point / tickSize);
   double lossPerLot = points * valuePerPointPerLot;
   if(lossPerLot <= 0.0) return 0.0;

   double lot = riskMoney / lossPerLot;
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);

   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot/step)*step;
   return NormalizeDouble(lot, 2);
}

bool BuySignal()
{
   int s = 1;
   double ema20 = iMA(Symbol(), PERIOD_M5, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, s);
   double ema50 = iMA(Symbol(), PERIOD_M5, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, s);
   if(!TouchesEMABand(s, ema20, ema50)) return false;

   double rsi1 = iRSI(Symbol(), PERIOD_M5, RSIPeriod, PRICE_CLOSE, s);
   double rsi2 = iRSI(Symbol(), PERIOD_M5, RSIPeriod, PRICE_CLOSE, s+1);
   if(!(rsi1 >= RSIZoneLow && rsi1 <= RSIZoneHigh && rsi1 > rsi2)) return false;

   double trigger = HighestHigh(2, BreakoutLookbackBars);
   double close1 = iClose(Symbol(), PERIOD_M5, s);
   return (close1 > trigger);
}

bool SellSignal()
{
   int s = 1;
   double ema20 = iMA(Symbol(), PERIOD_M5, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, s);
   double ema50 = iMA(Symbol(), PERIOD_M5, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, s);
   if(!TouchesEMABand(s, ema20, ema50)) return false;

   double rsi1 = iRSI(Symbol(), PERIOD_M5, RSIPeriod, PRICE_CLOSE, s);
   double rsi2 = iRSI(Symbol(), PERIOD_M5, RSIPeriod, PRICE_CLOSE, s+1);
   if(!(rsi1 >= (100.0-RSIZoneHigh) && rsi1 <= (100.0-RSIZoneLow) && rsi1 < rsi2)) return false;

   double trigger = LowestLow(2, BreakoutLookbackBars);
   double close1 = iClose(Symbol(), PERIOD_M5, s);
   return (close1 < trigger);
}

void ManageOpenPosition()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;

      if(OrderType()==OP_BUY)
      {
         double ema1 = iMA(Symbol(), PERIOD_M5, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
         double ema2 = iMA(Symbol(), PERIOD_M5, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 2);
         double c1 = iClose(Symbol(), PERIOD_M5, 1), c2 = iClose(Symbol(), PERIOD_M5, 2);
         if(c1 < ema1 && c2 >= ema2)
         {
            if(!OrderClose(OrderTicket(), OrderLots(), Bid, 30, clrRed))
               Print("OrderClose(BUY) failed. err=", GetLastError());
            continue;
         }

         double fract;
         if(FindLatestFractalLow(fract))
         {
            double newSL = fract - SlBufferPoints*Point;
            if(newSL > OrderStopLoss() && newSL < Bid)
               if(!OrderModify(OrderTicket(), OrderOpenPrice(), NormalizeDouble(newSL, Digits), 0, 0, clrBlue))
                  Print("OrderModify(BUY) failed. err=", GetLastError());
         }
      }
      else if(OrderType()==OP_SELL)
      {
         double ema1 = iMA(Symbol(), PERIOD_M5, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
         double ema2 = iMA(Symbol(), PERIOD_M5, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 2);
         double c1 = iClose(Symbol(), PERIOD_M5, 1), c2 = iClose(Symbol(), PERIOD_M5, 2);
         if(c1 > ema1 && c2 <= ema2)
         {
            if(!OrderClose(OrderTicket(), OrderLots(), Ask, 30, clrRed))
               Print("OrderClose(SELL) failed. err=", GetLastError());
            continue;
         }

         double fract;
         if(FindLatestFractalHigh(fract))
         {
            double spreadPts = MarketInfo(Symbol(), MODE_SPREAD);
            double newSL = fract + (spreadPts + SlBufferPoints)*Point;
            if((OrderStopLoss()==0.0 || newSL < OrderStopLoss()) && newSL > Ask)
               if(!OrderModify(OrderTicket(), OrderOpenPrice(), NormalizeDouble(newSL, Digits), 0, 0, clrBlue))
                  Print("OrderModify(SELL) failed. err=", GetLastError());
         }
      }
   }
}

int OnInit()
{
   PEAK_BALANCE_KEY = "DirectionalPullbackEA_peak_" + IntegerToString(AccountNumber());
   UpdatePeakBalance();
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(Period() != PERIOD_M5) return;
   if(!IsAllowedSymbol()) return;
   if(!InSession()) return;
   if(MarketInfo(Symbol(), MODE_SPREAD) > MaxSpreadPoints) return;

   UpdatePeakBalance();

   if(IsNewBar()) ManageOpenPosition();
   if(HasOpenPositionForSymbol()) return;

   int dir = DirectionMode;
   if(dir==0 || dir==2)
   {
      if(BuySignal())
      {
         double fract;
         if(!FindLatestFractalLow(fract)) return;
         double sl = fract - SlBufferPoints*Point;
         double entry = Ask;
         double lot = CalcLotByRisk(entry - sl);
         if(lot > 0.0 && sl < entry)
         {
            int tkBuy = OrderSend(Symbol(), OP_BUY, lot, Ask, 30, NormalizeDouble(sl, Digits), 0, "DirPullbackEA", MagicNumber, 0, clrGreen);
            if(tkBuy < 0) Print("OrderSend(BUY) failed. err=", GetLastError());
         }
      }
   }

   if(dir==1 || dir==2)
   {
      if(SellSignal())
      {
         double fract;
         if(!FindLatestFractalHigh(fract)) return;
         double spreadPts = MarketInfo(Symbol(), MODE_SPREAD);
         double sl = fract + (spreadPts + SlBufferPoints)*Point;
         double entry = Bid;
         double lot = CalcLotByRisk(sl - entry);
         if(lot > 0.0 && sl > entry)
         {
            int tkSell = OrderSend(Symbol(), OP_SELL, lot, Bid, 30, NormalizeDouble(sl, Digits), 0, "DirPullbackEA", MagicNumber, 0, clrGreen);
            if(tkSell < 0) Print("OrderSend(SELL) failed. err=", GetLastError());
         }
      }
   }
}
