import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const VayuWatchApp());

class AqiLevel {
  final int max;
  final String label, emoji;
  final Color color, darkColor, bg;
  final String advice;
  const AqiLevel(this.max, this.label, this.emoji, this.color, this.darkColor, this.bg, this.advice);
}

const List<AqiLevel> aqiLevels = [
  AqiLevel(50,  'Good',                           '🟢', Color(0xFF16a34a), Color(0xFF15803d), Color(0xFFdcfce7), 'Great day to be outdoors!'),
  AqiLevel(100, 'Moderate',                       '🟡', Color(0xFFca8a04), Color(0xFFa16207), Color(0xFFfef9c3), 'Sensitive individuals take care.'),
  AqiLevel(150, 'Unhealthy for Sensitive Groups', '🟠', Color(0xFFea580c), Color(0xFFc2410c), Color(0xFFffedd5), 'Sensitive groups reduce outdoor time.'),
  AqiLevel(200, 'Unhealthy',                      '🔴', Color(0xFFdc2626), Color(0xFFb91c1c), Color(0xFFfee2e2), 'Reduce prolonged outdoor exertion.'),
  AqiLevel(300, 'Very Unhealthy',                 '🟣', Color(0xFF9333ea), Color(0xFF7e22ce), Color(0xFFf3e8ff), 'Avoid outdoor activities.'),
  AqiLevel(500, 'Hazardous',                      '⚫', Color(0xFF7f1d1d), Color(0xFF450a0a), Color(0xFFfca5a5), 'Stay indoors. Mask required outside.'),
];

AqiLevel getAqiLevel(int aqi) =>
    aqiLevels.firstWhere((l) => aqi <= l.max, orElse: () => aqiLevels.last);

class City {
  final String name, state;
  final double lat, lon;
  const City(this.name, this.state, this.lat, this.lon);
}

const List<City> cities = [
  City('Bengaluru', 'KA', 12.9716, 77.5946),
  City('Delhi',     'DL', 28.6139, 77.2090),
  City('Mumbai',    'MH', 19.0760, 72.8777),
  City('Hyderabad', 'TS', 17.3850, 78.4867),
  City('Chennai',   'TN', 13.0827, 80.2707),
];

class HistoryPoint {
  final String time;
  final int aqi;
  const HistoryPoint(this.time, this.aqi);
}

final _rng = Random();
int _generateAqi(int base) => (base + (_rng.nextDouble() - 0.5) * 40).round().clamp(10, 400);

List<HistoryPoint> _generateHistory(int base) {
  final now = DateTime.now();
  return List.generate(12, (i) {
    final h = now.subtract(Duration(hours: 11 - i));
    return HistoryPoint('${h.hour}:00', _generateAqi((base + sin(i / 3) * 30).round()));
  });
}

Map<String, double> _generatePollutants(int aqi) {
  final s = aqi / 100;
  return {
    'PM2.5': double.parse((15 * s + _rng.nextDouble() * 10).toStringAsFixed(1)),
    'PM10':  double.parse((30 * s + _rng.nextDouble() * 15).toStringAsFixed(1)),
    'NO2':   double.parse((40 * s + _rng.nextDouble() * 20).toStringAsFixed(1)),
    'SO2':   double.parse((10 * s + _rng.nextDouble() * 8).toStringAsFixed(1)),
    'CO':    double.parse((0.8 * s + _rng.nextDouble() * 0.5).toStringAsFixed(2)),
    'O3':    double.parse((50 * s + _rng.nextDouble() * 25).toStringAsFixed(1)),
  };
}

int _baseAqi(City city) {
  switch (city.name) {
    case 'Delhi':     return 200;
    case 'Mumbai':    return 130;
    case 'Hyderabad': return 110;
    case 'Chennai':   return 95;
    default:          return 75;
  }
}

// ─── App ──────────────────────────────────────────────────────────────────────
class VayuWatchApp extends StatelessWidget {
  const VayuWatchApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'VayuWatch',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF0f172a)),
        home: const HomeScreen(),
      );
}

// ─── Home ─────────────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  City? _city;
  int? _aqi;
  double? _temp;
  int? _humidity;
  double? _windKmh;
  List<HistoryPoint> _history = [];
  Map<String, double> _pollutants = {};
  bool _loading = false;
  DateTime? _updatedAt;
  int _tab = 0;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() { if (!_tabController.indexIsChanging) setState(() => _tab = _tabController.index); });
  }

  @override
  void dispose() { _tabController.dispose(); super.dispose(); }

  void _loadCity(City city) {
    setState(() { _loading = true; _city = city; });
    Future.delayed(const Duration(milliseconds: 600), () async {
      if (!mounted) return;
      final base = _baseAqi(city);
      final aqi  = _generateAqi(base);
      // try to fetch real weather for this city (non-blocking if it fails)
      await _fetchWeather(city.lat, city.lon);
      setState(() {
        _aqi        = aqi;
        _history    = _generateHistory(base);
        _pollutants = _generatePollutants(aqi);
        _updatedAt  = DateTime.now();
        _loading    = false;
      });
    });
  }

  void _handleGps() async {
    // Try to get device location; fall back to bundled fake coord if unavailable
    Position? pos;
    try {
      pos = await _getCurrentPosition();
    } catch (_) { pos = null; }

    double lat, lon;
    if (pos != null) {
      lat = pos.latitude; lon = pos.longitude;
    } else {
      lat = 12.97; lon = 77.59; // fallback (Bengaluru)
    }

    // find nearest known city
    City nearest = cities[0];
    double minD = double.infinity;
    for (final c in cities) {
      final d = sqrt(pow(c.lat - lat, 2) + pow(c.lon - lon, 2));
      if (d < minD) { minD = d; nearest = c; }
    }

    await _fetchWeather(lat, lon);
    _loadCity(nearest);
  }

  Future<Position?> _getCurrentPosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    if (permission == LocationPermission.deniedForever) return null;
    return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.best);
  }

  Future<bool> _fetchWeather(double lat, double lon) async {
    try {
      const apiKey = 'YOUR_OPENWEATHERMAP_API_KEY';
      final url = Uri.parse('https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&appid=$apiKey&units=metric');
      final resp = await http.get(url).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return false;
      final j = json.decode(resp.body) as Map<String, dynamic>;
      setState(() {
        _temp = (j['main']?['temp'] as num?)?.toDouble();
        _humidity = (j['main']?['humidity'] as num?)?.toInt();
        final windMs = (j['wind']?['speed'] as num?)?.toDouble() ?? 0.0;
        _windKmh = windMs * 3.6;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0f172a),
    body: SafeArea(
      child: Column(children: [
        _buildHeader(),
        Expanded(
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFf8fafc),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            clipBehavior: Clip.antiAlias,
            child: _loading ? _buildLoading() : _buildContent(),
          ),
        ),
      ]),
    ),
  );

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
            child: const Text('VAYUWATCH', style: TextStyle(fontSize: 10, letterSpacing: 2.5, color: Color(0xFF94a3b8), fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 6),
          RichText(text: const TextSpan(children: [
            TextSpan(text: 'Air Quality\n', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white, height: 1.2)),
            TextSpan(text: 'Monitor', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w300, color: Color(0xFF64748b))),
          ])),
        ]),
        GestureDetector(
          onTap: _handleGps,
          child: Column(children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xFF1e40af), borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.my_location, color: Colors.white, size: 22),
            ),
            const SizedBox(height: 5),
            const Text('GPS', style: TextStyle(fontSize: 10, color: Color(0xFF64748b))),
          ]),
        ),
      ]),
      const SizedBox(height: 16),
      SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: cities.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final c = cities[i]; final sel = _city?.name == c.name;
            return GestureDetector(
              onTap: () => _loadCity(c),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: sel ? Colors.white : Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(c.name, style: TextStyle(
                  color: sel ? const Color(0xFF0f172a) : const Color(0xFFcbd5e1),
                  fontSize: 13, fontWeight: sel ? FontWeight.w700 : FontWeight.w400)),
              ),
            );
          },
        ),
      ),
    ]),
  );

  Widget _buildLoading() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const CircularProgressIndicator(color: Color(0xFF3b82f6)),
    const SizedBox(height: 14),
    Text('Scanning ${_city?.name ?? ''}…', style: const TextStyle(color: Color(0xFF64748b), fontSize: 14)),
  ]));

  Widget _buildContent() {
    if (_city == null || _aqi == null) return _buildEmpty();
    final level = getAqiLevel(_aqi!);
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildHeroBanner(level),
        _buildTabBar(),
        if (_tab == 0) _buildOverview(level),
        if (_tab == 1) _buildTrend(level),
        if (_tab == 2) _buildPollutants(),
        const SizedBox(height: 32),
      ]),
    );
  }

  Widget _buildEmpty() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(color: const Color(0xFFe0f2fe), borderRadius: BorderRadius.circular(28)),
      child: const Text('🌫️', style: TextStyle(fontSize: 52)),
    ),
    const SizedBox(height: 20),
    const Text('Select a city to begin', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF0f172a))),
    const SizedBox(height: 6),
    const Text('Tap a city above or use GPS', style: TextStyle(fontSize: 13, color: Color(0xFF64748b))),
  ]));

  Widget _buildHeroBanner(AqiLevel level) {
    final timeStr = _updatedAt != null
        ? '${_updatedAt!.hour.toString().padLeft(2,'0')}:${_updatedAt!.minute.toString().padLeft(2,'0')}'
        : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [level.color, level.darkColor],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: level.color.withOpacity(0.35), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Stack(children: [
        Positioned(right: -20, top: -20,
          child: Container(width: 120, height: 120,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(0.07)))),
        Positioned(right: 30, bottom: -30,
          child: Container(width: 90, height: 90,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(0.05)))),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.location_on, color: Colors.white70, size: 14),
                const SizedBox(width: 4),
                Text('${_city!.name}, ${_city!.state}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
              const SizedBox(height: 8),
              Text('${level.emoji}  ${level.label}',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(level.advice,
                  style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Updated $timeStr',
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ])),
            const SizedBox(width: 12),
            AqiGauge(aqi: _aqi!),
          ]),
        ),
      ]),
    );
  }

  Widget _buildTabBar() => Container(
    margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: const Color(0xFFe2e8f0), borderRadius: BorderRadius.circular(14)),
    child: TabBar(
      controller: _tabController,
      indicator: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 4)],
      ),
      labelColor: const Color(0xFF0f172a),
      unselectedLabelColor: const Color(0xFF64748b),
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.tab,
      tabs: const [Tab(text: 'Overview'), Tab(text: '24h Trend'), Tab(text: 'Pollutants')],
    ),
  );

  Widget _buildOverview(AqiLevel level) {
    final aqi = _aqi!;
    return Padding(
      key: const ValueKey('overview'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildAqiMeter(aqi, level),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: level.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: level.color.withOpacity(0.3)),
          ),
          child: Row(children: [
            Text(level.emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(child: Text(level.advice,
                style: TextStyle(fontSize: 13, color: level.darkColor, fontWeight: FontWeight.w500))),
          ]),
        ),
        const SizedBox(height: 16),
        const Text('Activity Guide',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF0f172a))),
        const SizedBox(height: 10),
        _buildActivityGrid(aqi),
        const SizedBox(height: 16),
        const Text('Conditions',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF0f172a))),
        const SizedBox(height: 10),
        _buildWeatherRow(aqi),
      ]),
    );
  }

  Widget _buildAqiMeter(int aqi, AqiLevel level) {
    const segs = [
      (Color(0xFF16a34a), '0'),
      (Color(0xFFca8a04), '50'),
      (Color(0xFFea580c), '100'),
      (Color(0xFFdc2626), '150'),
      (Color(0xFF9333ea), '200'),
      (Color(0xFF7f1d1d), '300'),
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFe2e8f0)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('AQI Scale', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: level.color, borderRadius: BorderRadius.circular(20)),
            child: Text('$aqi  •  ${level.label}',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Row(children: segs.map((s) => Expanded(
            child: Container(height: 10, color: s.$1),
          )).toList()),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(builder: (ctx, c) {
          final pct = (aqi / 500).clamp(0.0, 1.0);
          return Stack(clipBehavior: Clip.none, children: [
            const SizedBox(height: 14, width: double.infinity),
            Positioned(
              left: (c.maxWidth * pct - 7).clamp(0, c.maxWidth - 14),
              top: 0,
              child: Container(width: 14, height: 14, decoration: BoxDecoration(
                color: level.color, shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [BoxShadow(color: level.color.withOpacity(0.5), blurRadius: 6)],
              )),
            ),
          ]);
        }),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: segs.map((s) => Text(s.$2, style: const TextStyle(fontSize: 9, color: Color(0xFF94a3b8)))).toList()),
      ]),
    );
  }

  Widget _buildActivityGrid(int aqi) {
    final items = [
      ('😷', 'Health Impact',    aqi < 50 ? 'None' : aqi < 100 ? 'Minor' : aqi < 150 ? 'Moderate' : 'High',
          aqi < 100 ? const Color(0xFF16a34a) : aqi < 150 ? const Color(0xFFca8a04) : const Color(0xFFdc2626)),
      ('🚶', 'Outdoor Activity', aqi < 100 ? 'Safe' : aqi < 150 ? 'Caution' : 'Avoid',
          aqi < 100 ? const Color(0xFF16a34a) : aqi < 150 ? const Color(0xFFca8a04) : const Color(0xFFdc2626)),
      ('🏫', 'Schools',          aqi < 150 ? 'Open' : 'At risk',
          aqi < 150 ? const Color(0xFF16a34a) : const Color(0xFFdc2626)),
      ('🚴', 'Cycling',          aqi < 100 ? 'Safe' : aqi < 200 ? 'Mask on' : 'Avoid',
          aqi < 100 ? const Color(0xFF16a34a) : aqi < 200 ? const Color(0xFFca8a04) : const Color(0xFFdc2626)),
    ];
    return GridView.count(
      crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10,
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.4,
      children: items.map((item) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFe2e8f0)),
        ),
        child: Row(children: [
          Text(item.$1, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(item.$2, style: const TextStyle(fontSize: 10, color: Color(0xFF94a3b8))),
            const SizedBox(height: 2),
            Text(item.$3, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: item.$4)),
          ])),
        ]),
      )).toList(),
    );
  }

  Widget _buildWeatherRow(int aqi) {
    final humidity = _humidity ?? (45 + _rng.nextInt(35));
    final temp     = _temp?.round() ?? (24 + _rng.nextInt(12));
    final wind     = _windKmh?.round() ?? (5  + _rng.nextInt(20));
    final items = [
      ('🌡️', '$temp°C', 'Temp'),
      ('💧', '$humidity%', 'Humidity'),
      ('🌬️', '${wind}km/h', 'Wind'),
      ('👁️', aqi < 100 ? '>10km' : aqi < 200 ? '5-10km' : '<5km', 'Visibility'),
    ];
    return Row(children: items.asMap().entries.map((e) => Expanded(
      child: Container(
        margin: EdgeInsets.only(right: e.key < items.length - 1 ? 8 : 0),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFe2e8f0)),
        ),
        child: Column(children: [
          Text(e.value.$1, style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 4),
          Text(e.value.$2, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF0f172a))),
          Text(e.value.$3, style: const TextStyle(fontSize: 9, color: Color(0xFF94a3b8))),
        ]),
      ),
    )).toList());
  }

  Widget _buildTrend(AqiLevel level) {
    if (_history.isEmpty) return const SizedBox();
    final values = _history.map((h) => h.aqi).toList();
    final minVal = values.reduce(min);
    final maxVal = values.reduce(max);
    final avgVal = (values.reduce((a, b) => a + b) / values.length).round();
    return Padding(
      key: const ValueKey('trend'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(children: [
        Row(children: [
          _statCard('Min', minVal, getAqiLevel(minVal).color),
          const SizedBox(width: 10),
          _statCard('Avg', avgVal, getAqiLevel(avgVal).color),
          const SizedBox(width: 10),
          _statCard('Max', maxVal, getAqiLevel(maxVal).color),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFe2e8f0)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Hourly AQI', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0f172a))),
            Text('Last 12 hours  •  ${_city!.name}', style: const TextStyle(fontSize: 11, color: Color(0xFF94a3b8))),
            const SizedBox(height: 16),
            SizedBox(height: 180, child: LineChartWidget(history: _history, color: level.color)),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFe2e8f0)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Hour-by-hour bars',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0f172a))),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: _history.map((h) {
                final pct = (h.aqi / 300).clamp(0.0, 1.0);
                final c   = getAqiLevel(h.aqi).color;
                return Expanded(child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      height: 64 * pct + 4,
                      decoration: BoxDecoration(
                        color: c.withOpacity(0.85),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(h.time.split(':')[0], style: const TextStyle(fontSize: 8, color: Color(0xFF94a3b8))),
                  ]),
                ));
              }).toList(),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _statCard(String label, int value, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(children: [
        Text('$value', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF64748b))),
      ]),
    ),
  );

  Widget _buildPollutants() {
    const maxRef = {'PM2.5': 60.0, 'PM10': 100.0, 'NO2': 80.0, 'SO2': 20.0, 'CO': 2.0, 'O3': 100.0};
    const display = {'NO2': 'NO₂', 'SO2': 'SO₂', 'O3': 'O₃'};
    const info = {
      'PM2.5': 'Fine particles — most dangerous',
      'PM10':  'Coarse dust particles',
      'NO2':   'Nitrogen dioxide from vehicles',
      'SO2':   'Sulphur dioxide from industry',
      'CO':    'Carbon monoxide — colourless gas',
      'O3':    'Ground-level ozone',
    };
    final keys = ['PM2.5', 'PM10', 'NO2', 'SO2', 'CO', 'O3'];
    Color barColor(double pct) => pct < 0.5 ? const Color(0xFF16a34a) : pct < 0.8 ? const Color(0xFFea580c) : const Color(0xFFdc2626);

    return Padding(
      key: const ValueKey('pollutants'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Top 2 highlight cards
        Row(children: keys.take(2).map((p) {
          final val  = _pollutants[p] ?? 0;
          final ref  = maxRef[p]!;
          final pct  = (val / ref).clamp(0.0, 1.0);
          final c    = barColor(pct);
          final unit = p == 'CO' ? 'mg/m³' : 'µg/m³';
          return Expanded(child: Container(
            margin: EdgeInsets.only(right: p == 'PM2.5' ? 10 : 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [c.withOpacity(0.12), c.withOpacity(0.03)],
                begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.withOpacity(0.25)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(display[p] ?? p, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: c)),
              const SizedBox(height: 4),
              Text('$val', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: c, height: 1)),
              Text(unit, style: TextStyle(fontSize: 10, color: c.withOpacity(0.7))),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: pct, minHeight: 5,
                  backgroundColor: c.withOpacity(0.15),
                  valueColor: AlwaysStoppedAnimation(c),
                ),
              ),
            ]),
          ));
        }).toList()),
        const SizedBox(height: 10),
        // Rest as compact list
        ...keys.skip(2).map((p) {
          final val  = _pollutants[p] ?? 0;
          final ref  = maxRef[p]!;
          final pct  = (val / ref).clamp(0.0, 1.0);
          final c    = barColor(pct);
          final unit = p == 'CO' ? 'mg/m³' : 'µg/m³';
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFe2e8f0)),
            ),
            child: Row(children: [
              SizedBox(width: 44,
                child: Text(display[p] ?? p,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c))),
              const SizedBox(width: 8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(info[p] ?? '', style: const TextStyle(fontSize: 10, color: Color(0xFF94a3b8))),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: pct, minHeight: 5,
                    backgroundColor: const Color(0xFFf1f5f9),
                    valueColor: AlwaysStoppedAnimation(c),
                  ),
                ),
              ])),
              const SizedBox(width: 12),
              Text('$val\n$unit',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c, height: 1.4)),
            ]),
          );
        }),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFf1f5f9), borderRadius: BorderRadius.circular(10)),
          child: const Row(children: [
            Icon(Icons.info_outline, size: 14, color: Color(0xFF64748b)),
            SizedBox(width: 8),
            Text('Reference standards by CPCB, India',
                style: TextStyle(fontSize: 11, color: Color(0xFF64748b))),
          ]),
        ),
      ]),
    );
  }
}

class AqiGauge extends StatelessWidget {
  final int aqi;
  const AqiGauge({super.key, required this.aqi});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 110, height: 110,
    child: CustomPaint(painter: _GaugePainter(aqi: aqi)),
  );
}

class _GaugePainter extends CustomPainter {
  final int aqi;
  _GaugePainter({required this.aqi});

  static const _segs = [
    (Color(0xFF22c55e), -135.0, -81.0),
    (Color(0xFFca8a04),  -81.0, -27.0),
    (Color(0xFFea580c),  -27.0,  27.0),
    (Color(0xFFdc2626),   27.0,  81.0),
    (Color(0xFF9333ea),   81.0, 108.0),
    (Color(0xFF7f1d1d),  108.0, 135.0),
  ];

  double _r(double d) => d * pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2 + 6;
    const r = 42.0;

    canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r),
      _r(135), _r(270), false,
      Paint()..color = Colors.white24..style = PaintingStyle.stroke..strokeWidth = 8..strokeCap = StrokeCap.round);

    for (final s in _segs) {
      canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r),
        _r(s.$2 + 90), _r(s.$3 - s.$2), false,
        Paint()..color = s.$1.withOpacity(0.9)..style = PaintingStyle.stroke..strokeWidth = 8..strokeCap = StrokeCap.round);
    }

    final pct = (aqi / 500).clamp(0.0, 1.0);
    final angle = _r(-135 + pct * 270 + 90);
    canvas.drawLine(Offset(cx, cy), Offset(cx + 36 * cos(angle), cy + 36 * sin(angle)),
      Paint()..color = Colors.white..strokeWidth = 2.5..strokeCap = StrokeCap.round);
    canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = Colors.white);

    (TextPainter(
      text: TextSpan(text: '$aqi', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white)),
      textDirection: TextDirection.ltr,
    )..layout()).paint(canvas, Offset(cx - 18, cy - 22));

    (TextPainter(
      text: const TextSpan(text: 'AQI', style: TextStyle(fontSize: 10, color: Colors.white60)),
      textDirection: TextDirection.ltr,
    )..layout()).paint(canvas, Offset(cx - 10, cy - 2));
  }

  @override
  bool shouldRepaint(_GaugePainter o) => o.aqi != aqi;
}

class LineChartWidget extends StatelessWidget {
  final List<HistoryPoint> history;
  final Color color;
  const LineChartWidget({super.key, required this.history, required this.color});
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _LinePainter(history: history, color: color),
    child: const SizedBox.expand(),
  );
}

class _LinePainter extends CustomPainter {
  final List<HistoryPoint> history;
  final Color color;
  _LinePainter({required this.history, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;
    const padL = 32.0, padR = 8.0, padT = 8.0, padB = 24.0;
    final w = size.width - padL - padR;
    final h = size.height - padT - padB;
    final values = history.map((p) => p.aqi.toDouble()).toList();
    final minV = values.reduce(min) - 15;
    final maxV = values.reduce(max) + 15;
    final range = (maxV - minV).clamp(1, double.infinity);

    double xOf(int i) => padL + (i / (history.length - 1)) * w;
    double yOf(double v) => padT + h - ((v - minV) / range) * h;

    // Grid lines
    final gp = Paint()..color = const Color(0xFFf1f5f9)..strokeWidth = 1;
    for (int g = 0; g <= 3; g++) {
      final y = padT + (g / 3) * h;
      canvas.drawLine(Offset(padL, y), Offset(padL + w, y), gp);
      _text(canvas, '${(maxV - (g / 3) * range).round()}', Offset(0, y - 7), 9, const Color(0xFF94a3b8));
    }
    for (int i = 0; i < history.length; i += 3) {
      _text(canvas, history[i].time.replaceAll(':00', 'h'), Offset(xOf(i) - 8, size.height - padB + 5), 9, const Color(0xFF94a3b8));
    }

    // Fill gradient
    final path = Path();
    for (int i = 0; i < history.length; i++) {
      i == 0 ? path.moveTo(xOf(i), yOf(values[i])) : path.lineTo(xOf(i), yOf(values[i]));
    }
    final fill = Path.from(path)
      ..lineTo(xOf(history.length - 1), padT + h)
      ..lineTo(padL, padT + h)..close();
    canvas.drawPath(fill, Paint()
      ..shader = LinearGradient(colors: [color.withOpacity(0.2), color.withOpacity(0.0)],
        begin: Alignment.topCenter, end: Alignment.bottomCenter)
        .createShader(Rect.fromLTWH(0, padT, w, h)));

    // Line
    canvas.drawPath(path, Paint()
      ..color = color..strokeWidth = 2.5..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);

    // Dots
    for (int i = 0; i < history.length; i += 3) {
      canvas.drawCircle(Offset(xOf(i), yOf(values[i])), 4, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(xOf(i), yOf(values[i])), 3, Paint()..color = color);
    }
  }

  void _text(Canvas canvas, String t, Offset o, double s, Color c) {
    (TextPainter(text: TextSpan(text: t, style: TextStyle(fontSize: s, color: c)), textDirection: TextDirection.ltr)..layout()).paint(canvas, o);
  }

  @override
  bool shouldRepaint(_LinePainter o) => o.history != history;
}