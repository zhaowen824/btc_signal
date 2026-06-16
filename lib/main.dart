import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
int _notificationId = 0;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
  const InitializationSettings initSettings = InitializationSettings(android: androidSettings, iOS: iosSettings);
  await flutterLocalNotificationsPlugin.initialize(initSettings);
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BTC事件合约信号',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Color(0xFF0A0E17),
        cardColor: Color(0xFF1A1F2B),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF1A1F2B),
          selectedItemColor: Colors.orangeAccent,
          unselectedItemColor: Colors.grey,
        ),
      ),
      home: MainTabPage(),
    );
  }
}

class MainTabPage extends StatefulWidget {
  @override
  _MainTabPageState createState() => _MainTabPageState();
}

class _MainTabPageState extends State<MainTabPage> {
  int _currentIndex = 0;
  final List<Widget> _pages = [HomePage(), MessagesPage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: '主页'),
          BottomNavigationBarItem(
            icon: Stack(
              children: [
                Icon(Icons.message),
                Positioned(
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.all(2),
                    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(10)),
                    constraints: BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text('3', style: TextStyle(color: Colors.white, fontSize: 10)),
                  ),
                ),
              ],
            ),
            label: '消息',
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> signals = [];
  Map<String, dynamic> latestSignal = {};
  double totalWinRate = 0.0;
  int totalTrades = 0;
  double todayWinRate = 0.0;
  int todayWins = 0, todayTotal = 0, currentStreak = 0;
  String session = '', direction = '';
  double entryPrice = 0;
  String signalTime = '', settleTime = '';
  int remainingSeconds = 0;
  Timer? _refreshTimer;
  Timer? _countdownTimer;
  Timer? _tickerTimer;
  Map<String, String> marketStatus = {'trend': '--', 'volatility': '--', 'kdj': '--', 'volume': '--'};
  bool _wsConnected = false;
  bool _httpAvailable = false;
  double _currentPrice = 0.0, _priceChangePercent = 0.0, _high24h = 0.0, _low24h = 0.0, _volume24h = 0.0;
  final SignalEngine _engine = SignalEngine();
  String _networkError = '';

  @override
  void initState() {
    super.initState();
    _initDatabase();
    _startSignalEngine();
    _loadStats();
    _startCountdown();
    _fetch24hTicker();
    _startTickerTimer();
  }

  void _initDatabase() async => await DatabaseHelper.instance.database;
  void _startSignalEngine() {
    _engine.start();
    _refreshTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      await _loadStats();
      setState(() {
        marketStatus = _engine.marketStatus;
        _wsConnected = _engine.isOnline;
        _httpAvailable = _engine.httpAvailable;
        _networkError = _engine.lastError;
      });
      _updateCountdown();
      await _fetchCurrentPrice();
    });
  }

  Future<void> _fetchCurrentPrice() async {
    try {
      final res = await http.get(Uri.parse('https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT'));
      if (res.statusCode == 200) setState(() => _currentPrice = double.parse(jsonDecode(res.body)['price']));
    } catch (e) {}
  }

  Future<void> _fetch24hTicker() async {
    try {
      final res = await http.get(Uri.parse('https://api.binance.com/api/v3/ticker/24hr?symbol=BTCUSDT'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _priceChangePercent = double.parse(data['priceChangePercent']);
          _high24h = double.parse(data['highPrice']);
          _low24h = double.parse(data['lowPrice']);
          _volume24h = double.parse(data['volume']);
        });
      }
    } catch (e) {}
  }

  void _startTickerTimer() => _tickerTimer = Timer.periodic(Duration(minutes: 1), (t) => _fetch24hTicker());

  Future<void> _loadStats() async {
    final total = await DatabaseHelper.instance.getWinRate();
    final today = await DatabaseHelper.instance.getTodayStats();
    final latest = await DatabaseHelper.instance.getLatestSignal();
    final list = await DatabaseHelper.instance.getRecentSignals(20);
    setState(() {
      totalWinRate = total['winRate'];
      totalTrades = total['total'];
      todayWinRate = today['winRate'];
      todayWins = today['wins'];
      todayTotal = today['total'];
      currentStreak = today['streak'];
      signals = list;
      if (latest.isNotEmpty) {
        latestSignal = latest;
        direction = latestSignal['direction'] ?? '';
        entryPrice = latestSignal['entry_price'] ?? 0;
        signalTime = latestSignal['signal_time'] ?? '';
        if (signalTime.isNotEmpty) {
          DateTime st = DateTime.parse(signalTime);
          settleTime = DateFormat('yyyy-MM-dd HH:mm:ss').format(st.add(Duration(minutes: 10)));
        }
        session = latestSignal['session'] ?? '';
      }
      _updateCountdown();
    });
  }

  void _startCountdown() => _countdownTimer = Timer.periodic(Duration(seconds: 1), (t) => _updateCountdown());
  void _updateCountdown() {
    if (signalTime.isEmpty) {
      remainingSeconds = 0;
      return;
    }
    DateTime expire = DateTime.parse(signalTime).add(Duration(minutes: 10));
    int diff = expire.difference(DateTime.now()).inSeconds;
    remainingSeconds = diff > 0 ? diff : 0;
    setState(() {});
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _countdownTimer?.cancel();
    _tickerTimer?.cancel();
    _engine.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('BTC事件合约信号助手'), centerTitle: true),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            GridView.count(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 1.2,
              children: [
                _buildInfoCard(
                  '当前市场状态',
                  Column(
                    children: [
                      _buildStatusItem('趋势', marketStatus['trend']!),
                      SizedBox(height: 6),
                      _buildStatusItem('波动率', marketStatus['volatility']!),
                      SizedBox(height: 6),
                      _buildStatusItem('KDJ', marketStatus['kdj']!),
                      SizedBox(height: 6),
                      _buildStatusItem('量能', marketStatus['volume']!),
                    ],
                  ),
                ),
                _buildInfoCard(
                  '最新信号',
                  Column(
                    children: [
                      Text(
                        direction.isEmpty ? '--' : (direction == 'long' ? '做多 ↑' : '做空 ↓'),
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: direction == 'long' ? Colors.green : Colors.red,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text('入场: ${entryPrice == 0 ? '--' : entryPrice.toStringAsFixed(2)} USDT'),
                      Text('时间: ${signalTime.isEmpty ? '--' : signalTime.substring(0, 16)}', style: TextStyle(fontSize: 12)),
                      if (remainingSeconds > 0)
                        Text(
                          '倒计时: ${remainingSeconds ~/ 60}:${(remainingSeconds % 60).toString().padLeft(2, '0')}',
                          style: TextStyle(color: Colors.orange),
                        ),
                      Text('时段: ${session.isEmpty ? '--' : session}'),
                      Text('置信度: SS级', style: TextStyle(color: Colors.orangeAccent)),
                    ],
                  ),
                ),
                _buildInfoCard(
                  'BTC实时价格',
                  Column(
                    children: [
                      Text(
                        _currentPrice == 0 ? '--' : _currentPrice.toStringAsFixed(2),
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.orangeAccent),
                      ),
                      Text('USDT'),
                      Text(
                        '${_priceChangePercent >= 0 ? '+' : ''}${_priceChangePercent.toStringAsFixed(2)}%',
                        style: TextStyle(color: _priceChangePercent >= 0 ? Colors.green : Colors.red),
                      ),
                      Text(
                        '24H高: ${_high24h.toStringAsFixed(2)}  低: ${_low24h.toStringAsFixed(2)}',
                        style: TextStyle(fontSize: 10),
                      ),
                      Text('24H量: ${_volume24h.toStringAsFixed(0)} BTC', style: TextStyle(fontSize: 10)),
                    ],
                  ),
                ),
                _buildInfoCard(
                  '当前网络状态',
                  Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: _wsConnected ? Colors.green : Colors.red),
                          ),
                          SizedBox(width: 8),
                          Text(
                            _wsConnected ? 'WebSocket已连' : 'WebSocket断开',
                            style: TextStyle(color: _wsConnected ? Colors.green : Colors.red),
                          ),
                        ],
                      ),
                      SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: _httpAvailable ? Colors.green : Colors.red),
                          ),
                          SizedBox(width: 8),
                          Text(
                            _httpAvailable ? 'HTTP正常' : 'HTTP异常',
                            style: TextStyle(color: _httpAvailable ? Colors.green : Colors.red),
                          ),
                        ],
                      ),
                      if (_networkError.isNotEmpty) Text(_networkError, style: TextStyle(fontSize: 10, color: Colors.red)),
                      Text('延迟: ${_engine.networkLatency} ms', style: TextStyle(fontSize: 10)),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 24),
            Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('胜率统计', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                    SizedBox(height: 12),
                    Text('总信号：$totalTrades场 胜率：${(totalWinRate * 100).toStringAsFixed(1)}%'),
                    Text('今日表现：${(todayWinRate * 100).toStringAsFixed(1)}% ($todayWins胜/$todayTotal场)'),
                    Text('当前：${currentStreak > 0 ? "$currentStreak连胜" : currentStreak < 0 ? "${-currentStreak}连败" : "无连胜/败"}'),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            Text('信号历史', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: signals.length,
              itemBuilder: (ctx, idx) {
                final s = signals[idx];
                final isWin = s['pnl'] != null && s['pnl'] > 0;
                final dirText = s['direction'] == 'long' ? '做多' : '做空';
                final timeStr = (s['signal_time'] ?? '').isEmpty ? '' : s['signal_time'].substring(0, 16);
                return Card(
                  margin: EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Icon(
                      s['direction'] == 'long' ? Icons.arrow_upward : Icons.arrow_downward,
                      color: s['direction'] == 'long' ? Colors.green : Colors.red,
                    ),
                    title: Text('$dirText @ ${s['entry_price'].toStringAsFixed(2)} USDT'),
                    subtitle: Text('$timeStr  ${s['pnl'] != null ? (isWin ? '盈利' : '亏损') : '未结算'}'),
                    trailing: s['pnl'] != null
                        ? Text(
                            '${s['pnl'] > 0 ? '+' : ''}${s['pnl']?.toStringAsFixed(2)}U',
                            style: TextStyle(color: isWin ? Colors.green : Colors.red),
                          )
                        : null,
                  ),
                );
              },
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
              child: Text(
                '⚠️ 风险提示：短线交易持仓时间短，注意快速止盈止损。需要全局代理/VPN才能获取行情。',
                style: TextStyle(color: Colors.redAccent, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(String title, Widget content) => Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
              SizedBox(height: 8),
              Expanded(child: content),
            ],
          ),
        ),
      );

  Widget _buildStatusItem(String label, String value) {
    Color color;
    switch (value) {
      case '上涨趋势':
      case '放量':
        color = Colors.green;
        break;
      case '下跌趋势':
      case '高波动':
      case '超买区':
      case '超卖区':
        color = Colors.redAccent;
        break;
      case '区间震荡':
      case '正常':
      case '中性':
      case '缩量':
      case '低波动':
        color = Colors.grey;
        break;
      default:
        color = Colors.grey;
    }
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey, fontSize: 12)),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      ),
    );
  }
}

class MessagesPage extends StatefulWidget {
  @override
  _MessagesPageState createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  List<Map<String, dynamic>> messages = [];

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    final signals = await DatabaseHelper.instance.getRecentSignals(100);
    setState(() {
      messages = signals.where((s) => s['pnl'] != null).toList();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('消息'), centerTitle: true),
        body: messages.isEmpty
            ? Center(child: Text('暂无消息'))
            : ListView.builder(
                itemCount: messages.length,
                itemBuilder: (ctx, idx) {
                  final m = messages[idx];
                  final isWin = m['pnl'] > 0;
                  final dirText = m['direction'] == 'long' ? '做多' : '做空';
                  final timeStr = (m['signal_time'] ?? '').isEmpty ? '' : m['signal_time'].substring(0, 16);
                  return Card(
                    margin: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: ListTile(
                      leading: Icon(isWin ? Icons.check_circle : Icons.cancel, color: isWin ? Colors.green : Colors.red),
                      title: Text('$dirText 信号 @ ${m['entry_price'].toStringAsFixed(2)} USDT'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('信号时间: $timeStr'),
                          Text('结算价: ${m['settle_price']?.toStringAsFixed(2)}'),
                          Text('盈亏: ${m['pnl'] > 0 ? '+' : ''}${m['pnl']?.toStringAsFixed(2)}U'),
                        ],
                      ),
                    ),
                  );
                },
              ),
      );
}

// ================== SignalEngine（完整策略） ==================
class SignalEngine {
  List<Map<String, dynamic>> _oneMinKlines = [];
  List<Map<String, dynamic>> _tenMinKlines = [];
  bool _inPosition = false;
  WebSocketChannel? _channel;
  Timer? _settleTimer;
  List<double> _jValues = [];
  Timer? _heartbeatTimer;
  int _reconnectCount = 0;
  bool _isOnline = false;
  int _latency = 0;
  DateTime? _lastPing;
  String _lastError = '';
  bool _httpAvailable = false;

  bool get isOnline => _isOnline;
  int get networkLatency => _latency;
  String get lastError => _lastError;
  bool get httpAvailable => _httpAvailable;

  void start() {
    _fetchInitialKlines();
    _connectWebSocket();
    _checkHttp();
  }

  void stop() {
    _channel?.sink.close();
    _heartbeatTimer?.cancel();
    _settleTimer?.cancel();
  }

  Future<void> _checkHttp() async {
    try {
      final res = await http.get(Uri.parse('https://api.binance.com/api/v3/ping')).timeout(Duration(seconds: 5));
      _httpAvailable = res.statusCode == 200;
    } catch (e) {
      _httpAvailable = false;
      _lastError = 'HTTP请求失败: $e';
    }
  }

  Future<void> _fetchInitialKlines() async {
    try {
      final response = await http.get(
          Uri.parse('https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=1m&limit=200'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        for (var k in data) {
          _oneMinKlines.add({
            'openTime': k[0],
            'open': double.parse(k[1]),
            'high': double.parse(k[2]),
            'low': double.parse(k[3]),
            'close': double.parse(k[4]),
            'volume': double.parse(k[5]),
            'closeTime': k[6],
          });
        }
        print('Initial klines loaded: ${_oneMinKlines.length}');
        _resample10min();
        _calculateKDJ();
      }
    } catch (e) {
      print('Fetch initial klines error: $e');
      _lastError = '初始K线拉取失败: $e';
    }
  }

  void _connectWebSocket() {
    _channel?.sink.close();
    _heartbeatTimer?.cancel();
    _reconnectCount++;

    try {
      _channel = WebSocketChannel.connect(Uri.parse('wss://stream.binance.com:9443/ws/btcusdt@kline_1m'));
      _reconnectCount = 0;
      _isOnline = true;
      _lastPing = DateTime.now();

      _heartbeatTimer = Timer.periodic(Duration(seconds: 30), (timer) {
        try {
          _lastPing = DateTime.now();
          _channel?.sink.add(jsonEncode({"ping": _lastPing!.millisecondsSinceEpoch}));
        } catch (e) {
          timer.cancel();
        }
      });

      _channel!.stream.listen(
        (data) {
          final json = jsonDecode(data);
          if (json.containsKey('pong')) {
            if (_lastPing != null) _latency = DateTime.now().difference(_lastPing!).inMilliseconds;
            return;
          }
          final k = json['k'];
          if (k['x'] == true) {
            final kline = {
              'openTime': k['t'],
              'open': double.parse(k['o']),
              'high': double.parse(k['h']),
              'low': double.parse(k['l']),
              'close': double.parse(k['c']),
              'volume': double.parse(k['v']),
              'closeTime': k['T'],
            };
            _oneMinKlines.add(kline);
            if (_oneMinKlines.length > 500) _oneMinKlines.removeAt(0);
            _onNewKline();
          }
        },
        onError: (e) {
          _isOnline = false;
          _lastError = 'WebSocket错误: $e';
          _heartbeatTimer?.cancel();
          final delay = Duration(seconds: _reconnectCount < 5 ? 3 : 10);
          Future.delayed(delay, _connectWebSocket);
        },
        onDone: () {
          _isOnline = false;
          _lastError = 'WebSocket断开';
          _heartbeatTimer?.cancel();
          final delay = Duration(seconds: _reconnectCount < 5 ? 3 : 10);
          Future.delayed(delay, _connectWebSocket);
        },
        cancelOnError: false,
      );
    } catch (e) {
      _isOnline = false;
      _lastError = 'WebSocket连接异常: $e';
      Future.delayed(Duration(seconds: 5), _connectWebSocket);
    }
  }

  void _onNewKline() {
    if (_oneMinKlines.length < 200) return;
    final lastClose = DateTime.fromMillisecondsSinceEpoch(_oneMinKlines.last['closeTime']);
    if (lastClose.minute % 10 == 0 && lastClose.second == 0) {
      _resample10min();
    }
    _evaluateSignal();
  }

  void _resample10min() {
    if (_oneMinKlines.length < 10) return;
    final start = _oneMinKlines.length - 10;
    final tenMin = {
      'open': _oneMinKlines[start]['open'],
      'high': _oneMinKlines.sublist(start).map((e) => e['high']).reduce((a, b) => a > b ? a : b),
      'low': _oneMinKlines.sublist(start).map((e) => e['low']).reduce((a, b) => a < b ? a : b),
      'close': _oneMinKlines.last['close'],
      'volume': _oneMinKlines.sublist(start).map((e) => e['volume']).reduce((a, b) => a + b),
      'closeTime': _oneMinKlines.last['closeTime'],
    };
    _tenMinKlines.add(tenMin);
    if (_tenMinKlines.length > 100) _tenMinKlines.removeAt(0);
    _calculateKDJ();
  }

  void _calculateKDJ() {
    if (_tenMinKlines.length < 9) return;
    final closes = _tenMinKlines.map((e) => e['close'] as double).toList();
    final highs = _tenMinKlines.map((e) => e['high'] as double).toList();
    final lows = _tenMinKlines.map((e) => e['low'] as double).toList();
    final int n = 9, m1 = 3, m2 = 3;
    List<double> k = [], d = [];
    for (int i = n - 1; i < closes.length; i++) {
      double high = highs.sublist(i - n + 1, i + 1).reduce((a, b) => a > b ? a : b);
      double low = lows.sublist(i - n + 1, i + 1).reduce((a, b) => a < b ? a : b);
      double rsv = ((closes[i] - low) / (high - low)) * 100;
      if (k.isEmpty) {
        k.add(50.0);
        d.add(50.0);
      } else {
        k.add((k.last * (m1 - 1) + rsv) / m1);
        d.add((d.last * (m2 - 1) + k.last) / m2);
      }
    }
    _jValues = List.generate(k.length, (i) => 3 * k[i] - 2 * d[i]);
  }

  bool _jTurnUp() {
    if (_jValues.length < 3) return false;
    return _jValues.last > _jValues[_jValues.length - 2] && _jValues[_jValues.length - 2] <= _jValues[_jValues.length - 3];
  }

  bool _jTurnDown() {
    if (_jValues.length < 3) return false;
    return _jValues.last < _jValues[_jValues.length - 2] && _jValues[_jValues.length - 2] >= _jValues[_jValues.length - 3];
  }

  void _evaluateSignal() {
    if (_inPosition) return;
    final last = _oneMinKlines.last;
    bool isHammer = _isHammer(last);
    bool isShootingStar = _isShootingStar(last);
    bool downtrend = _isDowntrend();
    bool uptrend = _isUptrend();
    if (isHammer && downtrend && _jTurnUp()) _generateSignal('long', last['close']);
    else if (isShootingStar && uptrend && _jTurnDown()) _generateSignal('short', last['close']);
  }

  bool _isHammer(Map<String, dynamic> k) {
    double body = (k['close'] - k['open']).abs();
    double upperShadow = k['high'] - (k['open'] > k['close'] ? k['open'] : k['close']);
    double lowerShadow = (k['open'] < k['close'] ? k['open'] : k['close']) - k['low'];
    double range = k['high'] - k['low'];
    return lowerShadow >= 2 * body && upperShadow < 0.5 * body && body <= 0.33 * range;
  }

  bool _isShootingStar(Map<String, dynamic> k) {
    double body = (k['close'] - k['open']).abs();
    double upperShadow = k['high'] - (k['open'] > k['close'] ? k['open'] : k['close']);
    double lowerShadow = (k['open'] < k['close'] ? k['open'] : k['close']) - k['low'];
    double range = k['high'] - k['low'];
    return upperShadow >= 2 * body && lowerShadow < 0.5 * body && body <= 0.33 * range;
  }

  bool _isDowntrend() {
    if (_oneMinKlines.length < 20) return false;
    double start = _oneMinKlines[_oneMinKlines.length - 20]['close'];
    double end = _oneMinKlines.last['close'];
    return end < start;
  }

  bool _isUptrend() {
    if (_oneMinKlines.length < 20) return false;
    double start = _oneMinKlines[_oneMinKlines.length - 20]['close'];
    double end = _oneMinKlines.last['close'];
    return end > start;
  }

  String _getSession(DateTime time) {
    int hour = time.hour;
    if (hour >= 23 || hour < 9) return '亚洲时段';
    if (hour >= 9 && hour < 18) return '欧洲时段';
    return '美洲时段';
  }

  void _generateSignal(String direction, double price) async {
    _inPosition = true;
    final now = DateTime.now();
    final session = _getSession(now);
    final signal = {
      'signal_time': now.toIso8601String(),
      'direction': direction,
      'entry_price': price,
      'level': 'SS',
      'session': session,
      'pnl': null,
      'settle_price': null,
    };
    await DatabaseHelper.instance.insertSignal(signal);
    final dirText = direction == 'long' ? '做多' : '做空';
    await _showNotification(
        'BTC事件合约信号', '$dirText信号 入场价: ${price.toStringAsFixed(2)} USDT  时段: $session');
    _settleTimer = Timer(Duration(minutes: 10), () => _settleSignal(signal, price));
  }

  void _settleSignal(Map<String, dynamic> signal, double entryPrice) async {
    double exitPrice = _oneMinKlines.last['open'];
    bool isWin = (signal['direction'] == 'long' && exitPrice > entryPrice) ||
        (signal['direction'] == 'short' && exitPrice < entryPrice);
    double pnl = isWin ? 4.0 : -5.0;
    await DatabaseHelper.instance.updateSignal(signal['signal_time'], pnl, exitPrice);
    final dirText = signal['direction'] == 'long' ? '做多' : '做空';
    final resultText = isWin ? '盈利 +${pnl.toStringAsFixed(1)}U' : '亏损 ${pnl.toStringAsFixed(1)}U';
    await _showNotification(
        'BTC事件合约结算', '$dirText信号  $resultText  结算价: ${exitPrice.toStringAsFixed(2)} USDT');
    _inPosition = false;
  }

  Future<void> _showNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'signal_channel', '交易信号',
      importance: Importance.max, priority: Priority.high, enableVibration: true,
    );
    const NotificationDetails details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());
    await flutterLocalNotificationsPlugin.show(++_notificationId, title, body, details);
  }

  Map<String, String> get marketStatus {
    Map<String, String> status = {};
    if (_oneMinKlines.length >= 20) {
      final closes = _oneMinKlines.sublist(_oneMinKlines.length - 20).map((e) => e['close'] as double).toList();
      final ma20 = closes.reduce((a, b) => a + b) / 20;
      final diff = (_oneMinKlines.last['close'] - ma20) / ma20 * 100;
      if (diff > 0.1) status['trend'] = '上涨趋势';
      else if (diff < -0.1) status['trend'] = '下跌趋势';
      else status['trend'] = '区间震荡';
    } else status['trend'] = '收集中';
    if (_oneMinKlines.length >= 50) {
      final atr10 = _calculateATR(10);
      final atr50 = _calculateATR(50);
      final ratio = atr10 / atr50;
      if (ratio > 1.5) status['volatility'] = '高波动';
      else if (ratio < 0.7) status['volatility'] = '低波动';
      else status['volatility'] = '正常';
    } else status['volatility'] = '收集中';
    if (_jValues.isNotEmpty) {
      final j = _jValues.last;
      if (j > 80) status['kdj'] = '超买区';
      else if (j < 20) status['kdj'] = '超卖区';
      else status['kdj'] = '中性';
    } else status['kdj'] = '收集中';
    if (_oneMinKlines.length >= 20) {
      final vol5 = _oneMinKlines.sublist(_oneMinKlines.length - 5).map((e) => e['volume'] as double).reduce((a, b) => a + b) /
          5;
      final vol20 =
          _oneMinKlines.sublist(_oneMinKlines.length - 20).map((e) => e['volume'] as double).reduce((a, b) => a + b) / 20;
      final ratio = vol5 / vol20;
      if (ratio > 1.3) status['volume'] = '放量';
      else if (ratio < 0.7) status['volume'] = '缩量';
      else status['volume'] = '正常';
    } else status['volume'] = '收集中';
    return status;
  }

  double _calculateATR(int period) {
    if (_oneMinKlines.length < period) return 0;
    List<double> trList = [];
    for (int i = _oneMinKlines.length - period; i < _oneMinKlines.length; i++) {
      final high = _oneMinKlines[i]['high'] as double;
      final low = _oneMinKlines[i]['low'] as double;
      double prevClose = i > 0 ? _oneMinKlines[i - 1]['close'] as double : low;
      final tr = [high - low, (high - prevClose).abs(), (low - prevClose).abs()].reduce((a, b) => a > b ? a : b);
      trList.add(tr);
    }
    return trList.reduce((a, b) => a + b) / period;
  }
}

// ================== DatabaseHelper ==================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  static Database? _database;
  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/signals.db';
    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE signals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            signal_time TEXT,
            direction TEXT,
            entry_price REAL,
            level TEXT,
            session TEXT,
            pnl REAL,
            settle_price REAL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE signals ADD COLUMN level TEXT');
          await db.execute('ALTER TABLE signals ADD COLUMN session TEXT');
        }
      },
    );
  }

  Future<void> insertSignal(Map<String, dynamic> signal) async {
    final db = await database;
    await db.insert('signals', signal);
  }

  Future<void> updateSignal(String signalTime, double pnl, double settlePrice) async {
    final db = await database;
    await db.update(
      'signals',
      {'pnl': pnl, 'settle_price': settlePrice},
      where: 'signal_time = ?',
      whereArgs: [signalTime],
    );
  }

  Future<Map<String, dynamic>> getWinRate() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) as total, SUM(CASE WHEN pnl > 0 THEN 1 ELSE 0 END) as wins
      FROM signals WHERE pnl IS NOT NULL
    ''');
    final total = result.first['total'] as int;
    final wins = result.first['wins'] as int;
    return {'winRate': total > 0 ? wins / total : 0.0, 'total': total, 'wins': wins};
  }

  Future<Map<String, dynamic>> getTodayStats() async {
    final db = await database;
    final todayStart = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final statResult = await db.rawQuery('''
      SELECT COUNT(*) as total, SUM(CASE WHEN pnl > 0 THEN 1 ELSE 0 END) as wins
      FROM signals WHERE signal_time LIKE ? AND pnl IS NOT NULL
    ''', ['$todayStart%']);
    final total = statResult.first['total'] as int;
    final wins = statResult.first['wins'] as int;
    final winRate = total > 0 ? wins / total : 0.0;

    final signals = await db.rawQuery('''
      SELECT pnl FROM signals WHERE signal_time LIKE ? AND pnl IS NOT NULL ORDER BY signal_time ASC
    ''', ['$todayStart%']);
    int streak = 0;
    if (signals.isNotEmpty) {
      bool lastWin = (signals.first['pnl'] as double) > 0;
      streak = lastWin ? 1 : -1;
      for (int i = 1; i < signals.length; i++) {
        bool currentWin = (signals[i]['pnl'] as double) > 0;
        if (currentWin == lastWin) {
          streak += currentWin ? 1 : -1;
        } else {
          break;
        }
        lastWin = currentWin;
      }
    }
    return {'winRate': winRate, 'total': total, 'wins': wins, 'streak': streak};
  }

  Future<Map<String, dynamic>> getLatestSignal() async {
    final db = await database;
    final result = await db.query('signals', orderBy: 'signal_time DESC', limit: 1);
    return result.isEmpty ? {} : result.first;
  }

  Future<List<Map<String, dynamic>>> getRecentSignals(int limit) async {
    final db = await database;
    return await db.query('signals', orderBy: 'signal_time DESC', limit: limit);
  }
}
