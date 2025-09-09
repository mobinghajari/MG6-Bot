//+------------------------------------------------------------------+
//| Expert Advisor: SpikeChannelPB_EA_v2.0                           |
//| Description: Implements the full Spike->Channel->Pullback logic  |
//|              with advanced risk management and state machine.    |
//| Author: Mobin Ghajari (Original Idea)       |
//+------------------------------------------------------------------+
#property strict
#property copyright "Mobin Ghajari (Concept)"
#property version   "2.00"
#property description "ربات اسپایک، کانال و پولبک با مدیریت ریسک پیشرفته"

#include <Trade/Trade.mqh>
CTrade trade;

// --- وضعیت فعلی ربات (State Machine)
class CState
  {
   public:
      virtual void Run(){}
      virtual string Name(){return "BASE";}
  };

class CStateSearching : public CState
  {
      void Run(){ Print("[SEARCHING] Run"); DetectSpike(); }
      string Name(){ return "SEARCHING"; }
  };

class CStateChannel : public CState
  {
      void Run(){ Print("[CHANNEL] Run"); DetectChannelAndBreakout(); }
      string Name(){ return "CHANNEL"; }
  };

class CStatePending : public CState
  {
      void Run(){ Print("[PENDING] Run"); ManagePendingOrder(); }
      string Name(){ return "PENDING"; }
  };

CStateSearching  stateSearching;
CStateChannel    stateChannel;
CStatePending    statePending;
CState          *currentState = &stateSearching;

//+------------------------------------------------------------------+
//| ورودی‌های کاربر (Inputs)                                           |
//+------------------------------------------------------------------+
//--- مدیریت ریسک و سرمایه (Risk Management)
input group           "Risk Management Settings"
input double          InpRisk_Per_Trade_Percent = 1.0;    // درصد ریسک در هر معامله
input int             InpMax_Daily_Losses       = 3;      // حداکثر تعداد ضرر در روز
input double          InpMax_Daily_Profit_Percent = 6.0;  // حداکثر سود روزانه (درصد)
input double          InpMax_Weekly_Profit_Percent= 18.0; // حداکثر سود هفتگی (درصد)

//--- پارامترهای استراتژی (Strategy Parameters)
input group           "Strategy Parameters"
input int             InpEma_Period             = 120;    // دوره میانگین متحرک (EMA)
// --- شاخص قدرت کندل
input int             InpAvgBodyPeriod          = 20;     // دوره میانگین اندازه بدنه
input double          InpBodyMultiplier         = 2.0;    // ضریب مقایسه با میانگین
input double          InpMinBodyPoints          = 30;     // حداقل اندازه بدنه برحسب پوینت
input int             InpSpike_Min_Candles      = 3;      // حداقل تعداد کندل برای اسپایک
input int             InpMaxChannelCandles      = 30;     // حداکثر زمان تشکیل کانال
input int             InpSL_Buffer_Points       = 50;     // فاصله اضافی حد ضرر به پوینت
input double          InpRetrace_Low_Fib        = 38.2;   // فیبوناچی پایین برای منطقه ورود
input double          InpRetrace_High_Fib       = 50.0;   // فیبوناچی بالا برای منطقه ورود
input double          InpTake_Profit_RR_Ratio   = 2.0;    // نسبت سود به ضرر (TP = R * Ratio)
input int             InpOrder_Expiry_Candles   = 6;      // انقضای سفارش پس از چند کندل

//--- تنظیمات بصری و فنی (Technical & Visual Settings)
input group           "Technical Settings"
input ulong           InpMagic_Number           = 202401; // شماره جادویی (Magic Number)

//--- متغیرهای عمومی برای ردیابی وضعیت (Global Tracking Variables)
//- مدیریت ریسک
double  dailyStartBalance   = 0;
double  weeklyStartBalance  = 0;
int     dailyLossCount      = 0;
datetime dateToday          = 0;
datetime dateWeek           = 0;
double  dayEquityHigh       = 0;
datetime lastStatsDay       = 0;

//- وضعیت استراتژی
int     spikeDirection      = 0;      // 1 برای صعودی, -1 برای نزولی
int     spikeEndBarIndex    = -1;     // ایندکس کندل پایانی اسپایک
double  channelLastSwing    = 0;      // آخرین سقف/کف کانال
int     breakoutBarIndex    = -1;     // ایندکس کندل شکست کانال
ulong   pendingOrderTicket  = 0;      // شماره تیکت سفارش در حال انتظار

//+------------------------------------------------------------------+
//| تابع راه‌اندازی اولیه ربات                                         |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagic_Number);
    trade.SetMarginMode();
    trade.SetTypeFillingBySymbol(_Symbol);

    ResetSessionCounters();
    dayEquityHigh = AccountInfoDouble(ACCOUNT_EQUITY);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| بازنشانی شمارنده‌های روزانه و هفتگی                                |
//+------------------------------------------------------------------+
void ResetSessionCounters()
{
    MqlDateTime time;
    TimeCurrent(time);
    
    // بازنشانی شمارنده روزانه
    if(dateToday != (datetime)time.day_of_year)
    {
        dateToday = (datetime)time.day_of_year;
        dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        dailyLossCount = 0;
        dayEquityHigh = AccountInfoDouble(ACCOUNT_EQUITY);
        Print("Daily counters have been reset. Day Start Balance: ", dailyStartBalance);
    }
    
    // بازنشانی شمارنده هفتگی (با شروع هفته جدید)
    if(dateWeek != (datetime)(time.day_of_week))
    {
        // اگر امروز دوشنبه است و شمارنده هفتگی برای امروز نیست، ریست کن
        if(time.day_of_week == 1 && dateWeek != (datetime)time.day_of_year)
        {
             dateWeek = (datetime)time.day_of_year;
             weeklyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
             Print("Weekly counters have been reset. Week Start Balance: ", weeklyStartBalance);
        }
        // اگر اولین اجرای ربات در هفته است
        else if(weeklyStartBalance == 0)
        {
             dateWeek = (datetime)time.day_of_year;
             weeklyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
             Print("Weekly counters initialized for the first time. Week Start Balance: ", weeklyStartBalance);
        }
    }
}

//+------------------------------------------------------------------+
//| بررسی فیلترهای مدیریت سرمایه                                       |
//+------------------------------------------------------------------+
bool CheckSessionFilters()
{
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    int maxDailyLosses = (int)(GlobalVariableCheck("MaxDailyLosses") ? GlobalVariableGet("MaxDailyLosses") : InpMax_Daily_Losses);
    double maxDailyProfit = GlobalVariableCheck("MaxDailyProfitPct") ? GlobalVariableGet("MaxDailyProfitPct") : InpMax_Daily_Profit_Percent;
    double maxWeeklyProfit = GlobalVariableCheck("MaxWeeklyProfitPct") ? GlobalVariableGet("MaxWeeklyProfitPct") : InpMax_Weekly_Profit_Percent;

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity > dayEquityHigh) dayEquityHigh = equity;
    if(dayEquityHigh > 0 && (dayEquityHigh - equity) / dayEquityHigh > 0.25)
    {
        for(int i=PositionsTotal()-1;i>=0;i--)
        {
            if(PositionGetTicket(i) > 0)
                trade.PositionClose(PositionGetTicket(i));
        }
        Print("Equity drawdown exceeded 25%. All positions closed.");
        return false;
    }
    
    // 1. فیلتر حداکثر ضرر روزانه
    if(dailyLossCount >= maxDailyLosses)
    {
        Print("Trading stopped for today: Maximum daily loss limit (", maxDailyLosses, ") reached.");
        return false;
    }
    
    // 2. فیلتر حداکثر سود روزانه
    double dailyProfitPct = (dailyStartBalance > 0) ? (currentBalance - dailyStartBalance) / dailyStartBalance * 100 : 0;
    if(dailyProfitPct >= maxDailyProfit)
    {
        Print("Trading stopped for today: Maximum daily profit target (", maxDailyProfit, "% ) reached.");
        return false;
    }

    // 3. فیلتر حداکثر سود هفتگی
    double weeklyProfitPct = (weeklyStartBalance > 0) ? (currentBalance - weeklyStartBalance) / weeklyStartBalance * 100 : 0;
    if(weeklyProfitPct >= maxWeeklyProfit)
    {
        Print("Trading stopped for the week: Maximum weekly profit target (", maxWeeklyProfit, "% ) reached.");
        return false;
    }
    
    return true; // ادامه معامله مجاز است
}

//+------------------------------------------------------------------+
//| منطق اصلی ربات که در هر تیک اجرا می‌شود                            |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. بازنشانی شمارنده‌های روزانه/هفتگی در صورت نیاز
    ResetSessionCounters();

    MqlDateTime now; TimeCurrent(now);
    if(lastStatsDay != 0 && lastStatsDay != (datetime)now.day_of_year)
        WriteDailyStats();
    lastStatsDay = (datetime)now.day_of_year;

    // 2. بررسی فیلترهای مدیریت سرمایه
    if(!CheckSessionFilters())
    {
        return; // اگر شرطی نقض شده، از ادامه کار انصراف بده
    }
    
    // 3. مدیریت سفارش در حال انتظار (اگر وجود دارد)
    if(pendingOrderTicket > 0)
    {
        ManagePendingOrder();
        return; // تا زمانی که سفارش باز است، کار دیگری نکن
    }

    // 4. بررسی پوزیشن های باز برای رسیدن به حد سود مشخص
    CheckOpenPositionsRR();
    // 5. اجرای منطق فقط روی کندل جدید
    static datetime lastBarTime = 0;
    datetime currentBarTime = (datetime)iTime(_Symbol, _Period, 0);
    if(currentBarTime == lastBarTime)
    {
        return;
    }
    lastBarTime = currentBarTime;

    // --- اجرای ماشین وضعیت استراتژی ---
    if(currentState)
        currentState->Run();

    RPC_Handle();
}

//+------------------------------------------------------------------+
//| گام اول: شناسایی اسپایک                                           |
//+------------------------------------------------------------------+
void DetectSpike()
{
    // دریافت داده‌های قیمتی و اندیکاتورها
    MqlRates rates[];
    int barsNeeded = InpSpike_Min_Candles + InpAvgBodyPeriod + 20;
    if(CopyRates(_Symbol, _Period, 0, barsNeeded, rates) < barsNeeded) return;
    ArraySetAsSeries(rates, true);

    double ema_values[];
    if(CopyBuffer(iMA(_Symbol, _Period, InpEma_Period, 0, MODE_EMA, PRICE_CLOSE), 0, 0, InpSpike_Min_Candles + 5, ema_values) <= 0) return;
    ArraySetAsSeries(ema_values, true);
    
    double avgBody = 0;
    for(int j = InpSpike_Min_Candles + 1; j <= InpSpike_Min_Candles + InpAvgBodyPeriod; j++)
        avgBody += MathAbs(rates[j].close - rates[j].open);
    avgBody /= InpAvgBodyPeriod;

    // بررسی برای اسپایک صعودی (Bullish Spike)
    bool isBullSpike = true;
    for(int i = 1; i <= InpSpike_Min_Candles; i++)
    {
        double body  = rates[i].close - rates[i].open;
        double range = rates[i].high - rates[i].low;
        if(!(body > 0 &&
             body >= InpMinBodyPoints * _Point &&
             body >= InpBodyMultiplier * avgBody &&
             rates[i].close >= rates[i].high - 0.25 * range &&
             rates[i].close > ema_values[i]))
        {
            isBullSpike = false;
            break;
        }
    }

    // بررسی برای اسپایک نزولی (Bearish Spike)
    bool isBearSpike = true;
    for(int i = 1; i <= InpSpike_Min_Candles; i++)
    {
        double body  = rates[i].open - rates[i].close;
        double range = rates[i].high - rates[i].low;
        if(!(body > 0 &&
             body >= InpMinBodyPoints * _Point &&
             body >= InpBodyMultiplier * avgBody &&
             rates[i].close <= rates[i].low + 0.25 * range &&
             rates[i].close < ema_values[i]))
        {
            isBearSpike = false;
            break;
        }
    }

    if(isBullSpike)
    {
        spikeDirection = 1;
        spikeEndBarIndex = 1;
        currentState = &stateChannel;
        Print("Bullish Spike detected. Switching to STATE_MONITORING_CHANNEL.");
    }
    else if(isBearSpike)
    {
        spikeDirection = -1;
        spikeEndBarIndex = 1;
        currentState = &stateChannel;
        Print("Bearish Spike detected. Switching to STATE_MONITORING_CHANNEL.");
    }
}

//+------------------------------------------------------------------+
//| گام دوم: شناسایی کانال و شکست آن                                   |
//+------------------------------------------------------------------+
// این یک نسخه ساده‌شده و قوی از تشخیص کانال است
void DetectChannelAndBreakout()
{
    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 0, 20, rates) < 20) return; // 20 کندل برای جستجوی نوسان کافی است
    ArraySetAsSeries(rates, true);

    // اگر بیش از زمان تعیین شده از اسپایک گذشت و کانالی تشکیل نشد، استراتژی را ریست کن
    if(rates[0].time - rates[spikeEndBarIndex].time > InpMaxChannelCandles * PeriodSeconds())
    {
        Print("Channel did not form within ", InpMaxChannelCandles, " candles. Resetting strategy.");
        ResetStrategyState();
        return;
    }

    // منطق تشخیص کانال و شکست برای اسپایک صعودی
    if(spikeDirection == 1)
    {
        // پیدا کردن آخرین کف نوسانی (Swing Low) بعد از اسپایک
        double lastLow = rates[spikeEndBarIndex].low;
        int lastLowIndex = spikeEndBarIndex;
        for(int i = spikeEndBarIndex - 1; i >= 1; i--)
        {
            if(rates[i].low < lastLow)
            {
                lastLow = rates[i].low;
                lastLowIndex = i;
            }
        }
        
        // اگر یک کف بالاتر (Higher Low) تشکیل شد
        if(lastLow > rates[spikeEndBarIndex].low)
        {
            channelLastSwing = lastLow;
            // حالا منتظر شکست این کف هستیم (پولبک)
            if(rates[1].close < channelLastSwing)
            {
                Print("Channel breakout (pullback) detected for Bullish setup. Bar index: 1");
                breakoutBarIndex = 1;
                PlaceTradeOrder();
            }
        }
    }
    // منطق تشخیص کانال و شکست برای اسپایک نزولی
    else if(spikeDirection == -1)
    {
        // پیدا کردن آخرین سقف نوسانی (Swing High) بعد از اسپایک
        double lastHigh = rates[spikeEndBarIndex].high;
        int lastHighIndex = spikeEndBarIndex;
        for(int i = spikeEndBarIndex - 1; i >= 1; i--)
        {
            if(rates[i].high > lastHigh)
            {
                lastHigh = rates[i].high;
                lastHighIndex = i;
            }
        }
        
        // اگر یک سقف پایین‌تر (Lower High) تشکیل شد
        if(lastHigh < rates[spikeEndBarIndex].high)
        {
            channelLastSwing = lastHigh;
            // حالا منتظر شکست این سقف هستیم (پولبک)
            if(rates[1].close > channelLastSwing)
            {
                Print("Channel breakout (pullback) detected for Bearish setup. Bar index: 1");
                breakoutBarIndex = 1;
                PlaceTradeOrder();
            }
        }
    }
}

//+------------------------------------------------------------------+
//| گام سوم: قرار دادن سفارش پس از شکست کانال                         |
//+------------------------------------------------------------------+
void PlaceTradeOrder()
{
    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, breakoutBarIndex, 1, rates) < 1) return;
    ArraySetAsSeries(rates, true);
    
    // محاسبه منطقه ورود بر اساس کندل شکست
    MqlRates breakoutCandle = rates[0];
    double fibLevelLow = breakoutCandle.low + (breakoutCandle.high - breakoutCandle.low) * InpRetrace_Low_Fib / 100.0;
    double fibLevelHigh= breakoutCandle.low + (breakoutCandle.high - breakoutCandle.low) * InpRetrace_High_Fib / 100.0;
    
    double entryPrice = (fibLevelLow + fibLevelHigh) / 2.0;
    double stopLoss, takeProfit;
    
    // محاسبه SL و TP
    if(spikeDirection == 1) // خرید
    {
        stopLoss = channelLastSwing - _Point * InpSL_Buffer_Points; // SL کمی پایین‌تر از آخرین کف کانال
        takeProfit = entryPrice + (entryPrice - stopLoss) * InpTake_Profit_RR_Ratio;
    }
    else // فروش
    {
        stopLoss = channelLastSwing + _Point * InpSL_Buffer_Points; // SL کمی بالاتر از آخرین سقف کانال
        takeProfit = entryPrice - (stopLoss - entryPrice) * InpTake_Profit_RR_Ratio;
    }

    // محاسبه حجم معامله بر اساس ریسک
    double lots = CalculateLotSize(entryPrice, stopLoss);
    if(lots <= 0)
    {
        Print("Invalid lot size calculation. Resetting strategy.");
        ResetStrategyState();
        return;
    }
    
    // بررسی تاخیر شبکه
    if(Ping() > 200)
    {
        Print("Latency too high. Aborting trade order.");
        return;
    }

    // قرار دادن سفارش Limit
    MqlTradeRequest request;
    MqlTradeResult result;
    ZeroMemory(request);
    ZeroMemory(result);
    
    request.action = TRADE_ACTION_PENDING;
    request.magic = InpMagic_Number;
    request.symbol = _Symbol;
    request.volume = lots;
    request.price = NormalizeDouble(entryPrice, _Digits);
    request.sl = NormalizeDouble(stopLoss, _Digits);
    request.tp = NormalizeDouble(takeProfit, _Digits);
    request.type = (spikeDirection == 1) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
    request.type_filling = (ENUM_ORDER_TYPE_FILLING)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    request.type_time = ORDER_TIME_GTC;
    
    if(OrderSend(request, result))
    {
        double priceDiff = MathAbs(result.price - entryPrice) / _Point;
        if(priceDiff > 30)
        {
            Print("Slippage too high (", priceDiff, " points). Closing.");
            if(result.order > 0) trade.OrderDelete(result.order);
            return;
        }
        if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
        {
            pendingOrderTicket = result.order;
            currentState = &statePending;
            Print("Pending order placed. Ticket: ", pendingOrderTicket, ". Waiting for trigger or expiry.");
        }
        else
        {
             Print("OrderSend failed. Retcode: ", result.retcode, ", Error: ", GetLastError());
             ResetStrategyState();
        }
    }
    else
    {
        Print("OrderSend failed. Error: ", GetLastError());
        ResetStrategyState();
    }
}

//+------------------------------------------------------------------+
//| مدیریت سفارش در حال انتظار (برای لغو در صورت انقضا)                 |
//+------------------------------------------------------------------+
void ManagePendingOrder()
{
    // بررسی اینکه آیا سفارش هنوز وجود دارد یا خیر
    if(!OrderSelect(pendingOrderTicket))
    {
        // اگر سفارش دیگر وجود ندارد (اجرا شده یا دستی لغو شده)
        ResetStrategyState();
        return;
    }
    
    // بررسی زمان انقضای سفارش
    long orderTime = OrderGetInteger(ORDER_TIME_SETUP);
    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 0, InpOrder_Expiry_Candles + 1, rates) < InpOrder_Expiry_Candles + 1) return;
    
    // اگر از زمان قرار دادن سفارش، بیشتر از N کندل گذشته باشد
    if(rates[0].time > orderTime + (InpOrder_Expiry_Candles * PeriodSeconds()))
    {
        MqlTradeRequest request;
        MqlTradeResult result;
        ZeroMemory(request);
        ZeroMemory(result);
        request.action = TRADE_ACTION_REMOVE;
        request.order = pendingOrderTicket;
        
        if(OrderSend(request, result))
        {
            Print("Pending order #", pendingOrderTicket, " expired and has been cancelled.");
        }
        else
        {
            Print("Failed to cancel expired order #", pendingOrderTicket, ". Error: ", GetLastError());
        }
        ResetStrategyState();
    }
}

//+------------------------------------------------------------------+
//| بررسی پوزیشن های باز و خروج در نسبت سود به ضرر مشخص             |
//+------------------------------------------------------------------+
void CheckOpenPositionsRR()
{
    for(int i=PositionsTotal()-1; i>=0; --i)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic_Number)
                continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                continue;

            long    type      = PositionGetInteger(POSITION_TYPE);
            double  openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double  slPrice   = PositionGetDouble(POSITION_SL);

            if(slPrice == 0.0)
                continue;

            double risk, target;
            if(type == POSITION_TYPE_BUY)
            {
                risk   = openPrice - slPrice;
                target = openPrice + risk * InpTake_Profit_RR_Ratio;
                double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if(bid >= target)
                {
                    trade.PositionClose(PositionGetTicket(i));
                    Print("Position closed at RR target. Ticket: ", PositionGetTicket(i));
                    ResetStrategyState();
                }
            }
            else if(type == POSITION_TYPE_SELL)
            {
                risk   = slPrice - openPrice;
                target = openPrice - risk * InpTake_Profit_RR_Ratio;
                double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                if(ask <= target)
                {
                    trade.PositionClose(PositionGetTicket(i));
                    Print("Position closed at RR target. Ticket: ", PositionGetTicket(i));
                    ResetStrategyState();
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| محاسبه حجم معامله بر اساس درصد ریسک                                |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry, double sl)
{
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = accountBalance * (InpRisk_Per_Trade_Percent / 100.0);
    
    double slPoints = MathAbs(entry - sl);
    if(slPoints == 0) return 0.0;

    double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    if(slPoints < stopsLevel)
    {
        Print("Stop loss distance ", slPoints, " less than minimum ", stopsLevel);
        return 0.0;
    }

    MqlTick last_tick;
    SymbolInfoTick(_Symbol, last_tick);
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(tick_value <= 0 || tick_size <= 0) return 0.01;

    double lot = (riskAmount * tick_size) / (slPoints * tick_value);
    
    // نرمال‌سازی و اعتبارسنجی حجم
    double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = floor(lot / vol_step) * vol_step;

    double min_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    if(lot < min_vol) lot = min_vol;
    if(lot > max_vol)
    {
        Print("Lot size exceeds maximum volume. Requested: ", lot, " Max: ", max_vol);
        lot = max_vol;
    }
    
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| مدیریت تراکنش‌های معاملاتی (برای شمارش ضرر)                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
    // فقط معاملات بسته شده توسط ربات خودمان را بررسی کن
    // در برخی نسخه‌های قدیمی MQL5 فیلد magic در ساختار MqlTradeTransaction تعریف نشده است
    // بنابراین فقط مقدار magic موجود در درخواست را بررسی می‌کنیم
    if(request.magic != InpMagic_Number) return;

    // اگر یک معامله (Deal) به تاریخچه اضافه شد
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        // دریافت اطلاعات معامله
        if(HistoryDealSelect(trans.deal))
        {
            // اگر معامله به دلیل بسته شدن یک پوزیشن بوده
            if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            {
                double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                if(profit < 0)
                {
                    dailyLossCount++;
                    Print("A losing trade was closed. Daily loss count is now: ", dailyLossCount);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| بازنشانی وضعیت استراتژی به حالت اولیه                             |
//+------------------------------------------------------------------+
void ResetStrategyState()
{
    currentState = &stateSearching;
    spikeDirection = 0;
    spikeEndBarIndex = -1;
    channelLastSwing = 0;
    breakoutBarIndex = -1;
    pendingOrderTicket = 0;
    // Print("Strategy state has been reset to STATE_SEARCHING_SPIKE.");
}

// ثبت آمار روزانه در فایل CSV
void WriteDailyStats()
{
    string path = "stats.csv";
    int handle = FileOpen(path, FILE_CSV|FILE_READ|FILE_WRITE|FILE_COMMON);
    if(handle != INVALID_HANDLE)
    {
        FileSeek(handle, 0, SEEK_END);
        int trades = HistoryDealsTotal();
        FileWrite(handle, TimeToString(TimeCurrent(), TIME_DATE), trades);
        FileClose(handle);
        Print("[STATS] daily row written");
    }
}

// --- JSON RPC endpoint stub for optimizer integration ---
void RPC_Handle()
{
    // TODO: implement external parameter updates via pipe
}
//+------------------------------------------------------------------+
