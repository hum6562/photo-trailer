import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import 'dart:math';

import 'services/trip_logic.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: PhotoMapScreen()
  ));
}

class PhotoMapScreen extends StatefulWidget {
  const PhotoMapScreen({super.key});
  @override
  State<PhotoMapScreen> createState() => _PhotoMapScreenState();
}

class _PhotoMapScreenState extends State<PhotoMapScreen> {
  GoogleMapController? _mapController;
  
  // 🔥 2번 기능: 선택 시점에 초기화하기 위해 nullable로 변경
  PageController? _pageController;
  int _lastSyncedIndex = -1;

  Set<Marker> _markers = {};
  Set<Marker> _allTripMarkers = {}; 
  Set<Polyline> _polylines = {};
  List<Trip> _trips = [];
  int? _selectedTripIndex;

  bool _isLoading = false;
  String _statusText = "준비 중...";
  int _processedCount = 0;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _buildTravelPath(loadAll: false));
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    if (_selectedTripIndex == null || _isLoading || _pageController == null || !_pageController!.hasClients) return;
    
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    if (allPhotos.isEmpty) return;

    double page = _pageController!.page ?? 0;
    int currentIndex = page.round().clamp(0, allPhotos.length - 1);
    
    if (_lastSyncedIndex != currentIndex) {
      _lastSyncedIndex = currentIndex;
      final loc = allPhotos[currentIndex].location;
      if (loc != null) {
        _mapController?.animateCamera(CameraUpdate.newLatLng(loc));
      }
    }
  }

  Future<void> _buildTravelPath({required bool loadAll}) async {
    setState(() { 
      _isLoading = true; 
      _statusText = loadAll ? "모든 사진 불러오는 중..." : "최근 3개월 사진 불러오는 중..."; 
      _processedCount = 0;
      _totalCount = 0;
    });

    final pm.PermissionState ps = await pm.PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) {
      setState(() => _isLoading = false);
      return;
    }

    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image, onlyAll: true);
    if (albums.isEmpty) return;

    int fetchCount = loadAll ? await albums[0].assetCountAsync : 5000;
    final assets = await albums[0].getAssetListRange(start: 0, end: fetchCount);
    DateTime threeMonthsAgo = DateTime.now().subtract(const Duration(days: 90));

    List<RawPhoto> rawPhotos = [];
    setState(() { _totalCount = assets.length; });

    int chunkSize = 100;
    for (int i = 0; i < assets.length; i += chunkSize) {
      if (!loadAll && assets[i].createDateTime.isBefore(threeMonthsAgo)) {
        setState(() { _totalCount = i; }); 
        break;
      }

      int end = (i + chunkSize < assets.length) ? i + chunkSize : assets.length;
      var chunk = assets.sublist(i, end);
      var locations = await Future.wait(chunk.map((a) => a.latlngAsync()));

      for (int j = 0; j < chunk.length; j++) {
        var asset = chunk[j];
        var loc = locations[j];
        
        rawPhotos.add(RawPhoto(
          id: asset.id,
          location: (loc != null && loc.latitude != 0) ? LatLng(loc.latitude, loc.longitude) : null,
          time: asset.createDateTime,
          width: asset.width.toDouble(),
          height: asset.height.toDouble(),
          isFavorite: asset.isFavorite,
          originalAsset: asset,
        ));
      }

      setState(() { 
        _processedCount = end; 
        _statusText = "사진 위치 쾌속으로 읽는 중... ($_processedCount / $_totalCount)"; 
      });
    }

    setState(() { _statusText = "사진 정리 중... (잠시만 기다려주세요)"; });
    final analyzedTrips = await compute(_runAnalysis, rawPhotos);

    analyzedTrips.sort((a, b) {
      if (a.isTrip && !b.isTrip) return -1; 
      if (!a.isTrip && b.isTrip) return 1;
      return b.totalPhotoCount.compareTo(a.totalPhotoCount); 
    });

    Set<Marker> overviewMarkers = {};
    final displayTrips = analyzedTrips.take(15).toList();

    for (int i = 0; i < displayTrips.length; i++) {
      final trip = displayTrips[i];
      if (trip.places.isEmpty) continue;
      
      final mainPlace = trip.mainPlace;
      final bestPhoto = mainPlace.representative.originalAsset;
      
      if (bestPhoto != null) {
        Color borderColor = trip.isTrip ? Colors.orangeAccent : Colors.white;
        
        overviewMarkers.add(Marker(
          markerId: MarkerId("ov_$i"),
          position: mainPlace.centroid,
          icon: await _getPhotoMarker(bestPhoto, borderColor, count: trip.totalPhotoCount),
          onTap: () => _onTripSelected(analyzedTrips.indexOf(trip)), 
        ));
      }
    }

    setState(() {
      _trips = analyzedTrips;
      _allTripMarkers = overviewMarkers;
      _markers = overviewMarkers;
      _isLoading = false;
      
      int tripCount = _trips.where((t) => t.isTrip).length;
      int dailyCount = _trips.length - tripCount;
      _statusText = "완료! (여행 $tripCount개, 일상 $dailyCount개)";
    });
  }

  static List<Trip> _runAnalysis(List<RawPhoto> photos) => UltimateTravelEngine().segment(photos);

  // 🔥 4번 기능: 두 지점 사이의 각도(방향) 계산
  double _calculateBearing(LatLng start, LatLng end) {
    double lat1 = start.latitude * pi / 180;
    double lon1 = start.longitude * pi / 180;
    double lat2 = end.latitude * pi / 180;
    double lon2 = end.longitude * pi / 180;

    double dLon = lon2 - lon1;
    double y = sin(dLon) * cos(lat2);
    double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    double bearing = atan2(y, x) * 180 / pi;
    return (bearing + 360) % 360;
  }

  // 🔥 4번 기능: 진행 방향 화살표 마커 생성 (불투명도 적용)
  Future<BitmapDescriptor> _getArrowMarker(double opacity) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 40.0;
    
    final paint = Paint()
      ..color = Colors.white.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(10, 25)
      ..lineTo(20, 10)
      ..lineTo(30, 25);
      
    // 그림자
    canvas.drawPath(path.shift(const Offset(0, 2)), Paint()
      ..color = Colors.black45.withOpacity(opacity * 0.5)
      ..style = PaintingStyle.stroke..strokeWidth = 5.0..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    // 화살표 본체
    canvas.drawPath(path, paint..color = Colors.orangeAccent.withOpacity(opacity));

    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
  }

  Future<void> _onTripSelected(int index) async {
    setState(() { _selectedTripIndex = index; _isLoading = true; });
    
    final trip = _trips[index];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    
    // 🔥 2번 기능: 대표 사진의 인덱스를 찾아 그 위치부터 시작
    int startIndex = 0;
    final mainAssetId = trip.mainPlace.representative.originalAsset?.id;
    if (mainAssetId != null) {
      startIndex = allPhotos.indexWhere((p) => p.originalAsset?.id == mainAssetId);
      if (startIndex == -1) startIndex = 0;
    }

    _pageController?.dispose();
    _pageController = PageController(viewportFraction: 0.25, initialPage: startIndex);
    _pageController!.addListener(_onPageScroll);
    
    Set<Marker> detailMarkers = {};
    
    // 장소 사진 마커 세팅
    for (int i = 0; i < trip.places.length; i++) {
      final asset = trip.places[i].representative.originalAsset;
      if (asset != null) {
        detailMarkers.add(Marker(
          markerId: MarkerId("pl$i"),
          position: trip.places[i].centroid,
          icon: await _getPhotoMarker(asset, Colors.white), 
          zIndex: 2, // 화살표보다 위에 오도록
        ));
      }
    }

    // 🔥 4번 기능: 루트 표시 및 화살표 추가
    if (trip.isTrip && trip.path.length > 1) {
      // 메인 선은 불투명도를 낮게 깔아줍니다
      _polylines = { 
        Polyline(
          polylineId: PolylineId("p$index"), 
          points: trip.path, 
          color: Colors.orange.withOpacity(0.4), 
          width: 5
        ) 
      };
      
      final engine = UltimateTravelEngine();
      for (int i = 0; i < trip.path.length - 1; i++) {
        LatLng p1 = trip.path[i];
        LatLng p2 = trip.path[i+1];
        
        // 거리가 너무 짧으면 화살표 그리지 않음
        if (engine.getDistance(p1, p2) < 2.0) continue; 
        
        double bearing = _calculateBearing(p1, p2);
        LatLng midPoint = LatLng((p1.latitude + p2.latitude) / 2, (p1.longitude + p2.longitude) / 2);
        
        // 다음 사진 방향으로 갈수록 불투명도를 다르게 (선택적)
        double progress = i / (trip.path.length - 1);
        double arrowOpacity = 1.0 - (progress * 0.4); // 뒤로 갈수록 살짝 투명해짐
        
        detailMarkers.add(Marker(
          markerId: MarkerId("arrow_$i"),
          position: midPoint,
          icon: await _getArrowMarker(arrowOpacity),
          rotation: bearing, 
          anchor: const Offset(0.5, 0.5),
          zIndex: 1, // 사진 밑에 깔림
        ));
      }
    } else {
      _polylines = {};
    }

    setState(() { _markers = detailMarkers; _isLoading = false; });
    if (trip.path.isNotEmpty) {
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_getBounds(trip.path), 70));
    }
  }

  LatLngBounds _getBounds(List<LatLng> points) {
    if (points.isEmpty) return LatLngBounds(southwest: const LatLng(0,0), northeast: const LatLng(0,0));
    double minLat = points[0].latitude, maxLat = points[0].latitude;
    double minLng = points[0].longitude, maxLng = points[0].longitude;
    for (var p in points) {
      minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude); maxLng = max(maxLng, p.longitude);
    }
    return LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
  }

  // 🔥 1번 기능: 카톡 알림처럼 배지가 사진 밖으로 튀어나오게 수정
  Future<BitmapDescriptor> _getPhotoMarker(pm.AssetEntity entity, Color borderColor, {int? count}) async {
    final data = await entity.thumbnailDataWithSize(const pm.ThumbnailSize(100, 100));
    if (data == null) return BitmapDescriptor.defaultMarker;
    final codec = await ui.instantiateImageCodec(data);
    final fi = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    
    // 전체 캔버스를 키우고 사진을 좌측 하단으로 밉니다.
    const double canvasSize = 85.0; 
    const double photoSize = 60.0; 
    const double dxOffset = 0.0;
    const double dyOffset = 20.0; 
    
    canvas.drawCircle(const Offset(photoSize/2 + dxOffset, photoSize/2 + dyOffset), photoSize/2, Paint()..color = borderColor);
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(dxOffset + 4, dyOffset + 4, photoSize - 8, photoSize - 8)));
    canvas.drawImageRect(fi.image, Rect.fromLTWH(0, 0, fi.image.width.toDouble(), fi.image.height.toDouble()), const Rect.fromLTWH(dxOffset, dyOffset, photoSize, photoSize), Paint());
    
    // 캔버스 우측 상단 모서리에 배지 그리기
    if (count != null && count > 0) {
      String text = count > 99 ? "99+" : count.toString();
      final textPainter = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      
      double badgeRadius = 13.0;
      Offset badgeCenter = const Offset(65.0, 15.0); 
      
      // 하얀색 테두리 추가
      canvas.drawCircle(badgeCenter, badgeRadius + 2.5, Paint()..color = Colors.white);
      canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = Colors.redAccent);
      
      textPainter.paint(canvas, Offset(badgeCenter.dx - textPainter.width/2, badgeCenter.dy - textPainter.height/2));
    }

    final img = await recorder.endRecording().toImage(canvasSize.toInt(), canvasSize.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return BitmapDescriptor.defaultMarker;
    return BitmapDescriptor.bytes(bytes.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("사진소"), backgroundColor: Colors.orangeAccent),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(target: LatLng(36.5, 127.5), zoom: 6.5),
            onMapCreated: (c) => _mapController = c,
            markers: _markers,
            polylines: _polylines,
            onTap: (_) { setState(() { _selectedTripIndex = null; _markers = _allTripMarkers; _polylines = {}; }); },
          ),
          Positioned(top: 20, left: 20, right: 20, child: _buildStatusCard()),
          
          if (_isLoading) _buildLoadingOverlay(),
          
          if (_selectedTripIndex != null) ...[
            Positioned(bottom: 20, left: 0, right: 0, child: _buildTripFilmStrip()),
            // 🔥 3번 기능: 화면 오른쪽 위로 세로방향 파노라마 스크롤바 추가
            Positioned(right: 15, top: 100, bottom: 160, width: 55, child: _buildVerticalFastScroller()),
          ],
        ],
      ),
      floatingActionButton: (_isLoading || _selectedTripIndex != null) ? null : FloatingActionButton.extended(
        onPressed: () => _buildTravelPath(loadAll: true),
        label: const Text("모든 사진 분석하기"),
        icon: const Icon(Icons.photo_library),
        backgroundColor: Colors.orangeAccent,
      ),
    );
  }

  Widget _buildStatusCard() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white.withAlpha(230), borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]),
    child: Text(_statusText, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _buildLoadingOverlay() {
    return Positioned(
      bottom: 50, left: 40, right: 40,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(15)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("데이터를 처리 중입니다...", style: TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _totalCount == 0 ? null : (_processedCount / _totalCount),
              backgroundColor: Colors.grey[700],
              color: Colors.orangeAccent,
            ),
            const SizedBox(height: 10),
            Text("$_processedCount / $_totalCount 장", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
      ),
    );
  }

  // 🔥 3번 기능: 3000장도 빠르게 넘길 수 있는 세로 스크롤러 위젯
  Widget _buildVerticalFastScroller() {
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4), 
        borderRadius: BorderRadius.circular(30)
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: allPhotos.length,
        itemBuilder: (context, idx) {
          final asset = allPhotos[idx].originalAsset;
          if (asset == null) return const SizedBox.shrink();
          
          return GestureDetector(
            onTap: () {
              // 탭하면 하단 뷰와 지도 모두 쾌속 이동
              _pageController?.animateToPage(idx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
              child: ClipOval(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: AssetEntityImage(asset, fit: BoxFit.cover, isOriginal: false, thumbnailSize: const pm.ThumbnailSize(60, 60)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTripFilmStrip() {
    if (_pageController == null) return const SizedBox.shrink();
    
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    
    return SizedBox(
      height: 120, 
      child: PageView.builder(
        controller: _pageController,
        itemCount: allPhotos.length,
        itemBuilder: (context, idx) {
          final asset = allPhotos[idx].originalAsset;
          if (asset == null) return const SizedBox.shrink();

          return AnimatedBuilder(
            animation: _pageController!,
            builder: (context, child) {
              double value = 1.0;
              if (_pageController!.position.haveDimensions) {
                value = _pageController!.page! - idx;
                value = (1 - (value.abs() * 0.3)).clamp(0.0, 1.0);
              }
              return Center(
                child: SizedBox(
                  height: Curves.easeOut.transform(value) * 100,
                  width: Curves.easeOut.transform(value) * 100,
                  child: Opacity(
                    opacity: value.clamp(0.4, 1.0), 
                    child: child,
                  ),
                ),
              );
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12), 
                child: AssetEntityImage(asset, fit: BoxFit.cover)
              )
            ),
          );
        },
      ),
    );
  }
}
