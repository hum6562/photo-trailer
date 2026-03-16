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
  
  PageController? _pageController;
  ScrollController? _verticalScrollController;
  bool _isRightDragging = false; // 🔥 우측 스크롤 드래그 상태 감지
  
  int _lastSyncedIndex = -1;

  Set<Marker> _markers = {};
  Set<Marker> _allTripMarkers = {}; 
  Set<Polyline> _polylines = {};
  List<Trip> _trips = [];
  int? _selectedTripIndex;

  bool _isGlobalLoading = false;
  bool _isTripLoading = false;
  String _statusText = "준비 중...";
  int _processedCount = 0;
  int _totalCount = 0;

  final Map<String, BitmapDescriptor> _photoIconCache = {};
  final Map<int, BitmapDescriptor> _arrowIconCache = {};
  final List<Marker> _currentTripPlaceMarkers = [];
  final List<Marker> _currentTripArrowMarkers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _buildTravelPath(loadAll: false));
  }

  @override
  void dispose() {
    _pageController?.dispose();
    _verticalScrollController?.dispose();
    super.dispose();
  }

  // 🔥 우측 스크롤을 드래그할 때 -> 하단 PageView 동기화
  void _onRightScroll() {
    if (_isRightDragging && _pageController != null && _pageController!.hasClients) {
      double targetPage = _verticalScrollController!.offset / 60.0;
      final trip = _trips[_selectedTripIndex!];
      int totalPhotos = trip.places.fold(0, (sum, p) => sum + p.photos.length);
      targetPage = targetPage.clamp(0.0, (totalPhotos - 1).toDouble());
      
      double pagePixel = targetPage * _pageController!.position.viewportDimension * _pageController!.viewportFraction;
      _pageController!.position.jumpTo(pagePixel);
    }
  }

  // 🔥 하단 PageView가 움직일 때 -> 우측 스크롤 동기화
  void _onPageScroll() {
    if (_selectedTripIndex == null || _isGlobalLoading || _isTripLoading || _pageController == null || !_pageController!.hasClients) return;
    
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    if (allPhotos.isEmpty) return;

    double page = _pageController!.page ?? 0;
    
    // 유저가 우측 스크롤을 직접 만지고 있지 않을 때만 동기화 (충돌 방지)
    if (_verticalScrollController != null && _verticalScrollController!.hasClients && !_isRightDragging) {
      _verticalScrollController!.jumpTo(page * 60.0);
    }

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
      _isGlobalLoading = true; 
      _statusText = loadAll ? "모든 사진 불러오는 중..." : "최근 3개월 사진 불러오는 중..."; 
      _processedCount = 0;
      _totalCount = 0;
    });

    final pm.PermissionState ps = await pm.PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) {
      setState(() => _isGlobalLoading = false);
      return;
    }

    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image, onlyAll: true);
    if (albums.isEmpty) return;

    int fetchCount = loadAll ? await albums[0].assetCountAsync : 5000;
    final assets = await albums[0].getAssetListRange(start: 0, end: fetchCount);
    DateTime threeMonthsAgo = DateTime.now().subtract(const Duration(days: 90));

    List<RawPhoto> rawPhotos = [];
    setState(() { _totalCount = assets.length; });

    // 🔥 속도 최적화: 250장씩 병렬 처리
    int chunkSize = 250;
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
      _isGlobalLoading = false;
      
      int tripCount = _trips.where((t) => t.isTrip).length;
      int dailyCount = _trips.length - tripCount;
      _statusText = "완료! (여행 $tripCount개, 일상 $dailyCount개)";
    });
  }

  static List<Trip> _runAnalysis(List<RawPhoto> photos) => UltimateTravelEngine().segment(photos);

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

  // 🔥 두 좌표 사이의 실제 거리(미터) 계산 공식 (Haversine)
  double _calcDistanceMeters(LatLng p1, LatLng p2) {
    var R = 6371e3; 
    var phi1 = p1.latitude * pi / 180;
    var phi2 = p2.latitude * pi / 180;
    var dPhi = (p2.latitude - p1.latitude) * pi / 180;
    var dLambda = (p2.longitude - p1.longitude) * pi / 180;
    var a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2);
    var c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  Future<BitmapDescriptor> _getArrowMarker(double opacity) async {
    int cacheKey = (opacity * 10).round();
    if (_arrowIconCache.containsKey(cacheKey)) return _arrowIconCache[cacheKey]!;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 40.0;
    
    final paint = Paint()..color = Colors.white.withValues(alpha: opacity)..style = PaintingStyle.stroke..strokeWidth = 4.0..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(10, 22)..lineTo(20, 8)..lineTo(30, 22)..moveTo(10, 32)..lineTo(20, 18)..lineTo(30, 32);
      
    canvas.drawPath(path.shift(const Offset(0, 2)), Paint()..color = Colors.black45.withValues(alpha: opacity * 0.5)..style = PaintingStyle.stroke..strokeWidth = 4.0..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    canvas.drawPath(path, paint..color = Colors.orangeAccent.withValues(alpha: opacity));

    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final marker = BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
    _arrowIconCache[cacheKey] = marker;
    return marker;
  }

  Future<void> _onTripSelected(int index) async {
    setState(() { _selectedTripIndex = index; _isTripLoading = true; _markers = {}; _polylines = {}; });
    
    final trip = _trips[index];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    
    int startIndex = 0;
    final mainAssetId = trip.mainPlace.representative.originalAsset?.id;
    if (mainAssetId != null) {
      startIndex = allPhotos.indexWhere((p) => p.originalAsset?.id == mainAssetId);
      if (startIndex == -1) startIndex = 0;
    }

    _lastSyncedIndex = startIndex; 

    // 하단 뷰 컨트롤러 리셋
    _pageController?.dispose();
    _pageController = PageController(viewportFraction: 0.25, initialPage: startIndex);
    _pageController!.addListener(_onPageScroll);

    // 우측 스크롤 컨트롤러 리셋 (해당 인덱스 위치로 초기 세팅)
    _verticalScrollController?.dispose();
    _verticalScrollController = ScrollController(initialScrollOffset: startIndex * 60.0);
    _verticalScrollController!.addListener(_onRightScroll);
    
    _currentTripPlaceMarkers.clear();
    _currentTripArrowMarkers.clear();
    
    for (int i = 0; i < trip.places.length; i++) {
      final asset = trip.places[i].representative.originalAsset;
      if (asset != null) {
        _currentTripPlaceMarkers.add(Marker(
          markerId: MarkerId("pl$i"),
          position: trip.places[i].centroid,
          icon: await _getPhotoMarker(asset, Colors.white), 
          zIndexInt: 2, 
          // 🔥 기능 추가: 지도에 뜬 마커를 눌러도 하단 & 우측 사진이 해당 사진으로 정중앙 배치됨
          onTap: () {
            int idx = allPhotos.indexWhere((p) => p.originalAsset?.id == asset.id);
            if (idx != -1) {
              _pageController?.animateToPage(idx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
            }
          }
        ));
      }
    }

    if (trip.isTrip && trip.path.length > 1) {
      _polylines = { 
        Polyline(polylineId: PolylineId("p$index"), points: trip.path, color: Colors.orange.withValues(alpha: 0.4), width: 5) 
      };
      
      final engine = UltimateTravelEngine();
      for (int i = 0; i < trip.path.length - 1; i++) {
        LatLng p1 = trip.path[i];
        LatLng p2 = trip.path[i+1];
        if (engine.getDistance(p1, p2) < 2.0) continue; 
        
        double bearing = _calculateBearing(p1, p2);
        LatLng midPoint = LatLng((p1.latitude + p2.latitude) / 2, (p1.longitude + p2.longitude) / 2);
        double progress = i / (trip.path.length - 1);
        double arrowOpacity = 1.0 - (progress * 0.5); 
        
        _currentTripArrowMarkers.add(Marker(
          markerId: MarkerId("arrow_$i"),
          position: midPoint,
          icon: await _getArrowMarker(arrowOpacity.clamp(0.2, 1.0)),
          rotation: bearing, 
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 1, 
        ));
      }
    }

    setState(() { _isTripLoading = false; });
    _filterMarkersByZoom(10.0);
    
    if (trip.path.isNotEmpty) {
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_getBounds(trip.path), 70));
    }
  }

  // 🔥 동적 50% 겹침 방지 필터 알고리즘
  void _filterMarkersByZoom(double zoom) {
    if (_selectedTripIndex == null) return;
    Set<Marker> visibleMarkers = {};
    
    // 현재 줌 레벨에서 '1픽셀'이 실제 몇 미터인지 계산 (한국 위도 기준 근사치)
    double metersPerPixel = 156543.03 * 0.803 / pow(2, zoom);
    // 마커 이미지 지름(80px)의 50%인 40픽셀 거리를 한계치로 설정
    double thresholdMeters = 40.0 * metersPerPixel; 

    // 1. 대표 사진 마커 필터링 (겹치면 숨김)
    for (var m in _currentTripPlaceMarkers) {
      bool overlaps = false;
      for (var v in visibleMarkers) {
        if (_calcDistanceMeters(m.position, v.position) < thresholdMeters) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) visibleMarkers.add(m);
    }
    
    // 2. 진행 방향 화살표 마커 필터링
    List<Marker> visibleArrows = [];
    for (var a in _currentTripArrowMarkers) {
      bool overlaps = false;
      for (var v in visibleArrows) {
        if (_calcDistanceMeters(a.position, v.position) < (thresholdMeters * 0.8)) { // 화살표는 조금 더 촘촘하게
          overlaps = true;
          break;
        }
      }
      if (!overlaps) visibleArrows.add(a);
    }
    visibleMarkers.addAll(visibleArrows);
    
    setState(() { _markers = visibleMarkers; });
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

  Future<BitmapDescriptor> _getPhotoMarker(pm.AssetEntity entity, Color borderColor, {int? count}) async {
    final String cacheKey = "${entity.id}_${count ?? 0}";
    if (_photoIconCache.containsKey(cacheKey)) return _photoIconCache[cacheKey]!;

    final data = await entity.thumbnailDataWithSize(const pm.ThumbnailSize(100, 100));
    if (data == null) return BitmapDescriptor.defaultMarker;
    final codec = await ui.instantiateImageCodec(data);
    final fi = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    
    const double canvasSize = 100.0; 
    const double photoSize = 65.0; 
    const double dxOffset = 10.0;
    const double dyOffset = 25.0; 
    
    canvas.drawCircle(const Offset(photoSize/2 + dxOffset, photoSize/2 + dyOffset), photoSize/2, Paint()..color = borderColor);
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(dxOffset + 4, dyOffset + 4, photoSize - 8, photoSize - 8)));
    canvas.drawImageRect(fi.image, Rect.fromLTWH(0, 0, fi.image.width.toDouble(), fi.image.height.toDouble()), const Rect.fromLTWH(dxOffset, dyOffset, photoSize, photoSize), Paint());
    
    if (count != null && count > 0) {
      String text = count > 99 ? "99+" : count.toString();
      final textPainter = TextPainter(text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
      double badgeRadius = 14.0;
      Offset badgeCenter = const Offset(75.0, 25.0); 
      canvas.drawCircle(badgeCenter, badgeRadius + 2.5, Paint()..color = Colors.white);
      canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = Colors.redAccent);
      textPainter.paint(canvas, Offset(badgeCenter.dx - textPainter.width/2, badgeCenter.dy - textPainter.height/2));
    }

    final img = await recorder.endRecording().toImage(canvasSize.toInt(), canvasSize.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final marker = BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
    _photoIconCache[cacheKey] = marker;
    return marker;
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
            onCameraIdle: () async {
              if (_selectedTripIndex != null && _mapController != null) {
                double zoom = await _mapController!.getZoomLevel();
                _filterMarkersByZoom(zoom);
              }
            },
            onTap: (_) { setState(() { _selectedTripIndex = null; _markers = _allTripMarkers; _polylines = {}; }); },
          ),
          Positioned(top: 20, left: 20, right: 20, child: _buildStatusCard()),
          
          if (_isTripLoading) 
            Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(backgroundColor: Colors.transparent, color: Colors.orangeAccent, minHeight: 5)),
          if (_isGlobalLoading) _buildLoadingOverlay(),
          
          if (_selectedTripIndex != null) ...[
            Positioned(bottom: 20, left: 0, right: 0, child: _buildTripFilmStrip()),
            Positioned(right: 15, top: 90, width: 60, child: _buildVerticalFastScroller()),
          ],
        ],
      ),
      floatingActionButton: (_isGlobalLoading || _selectedTripIndex != null) ? null : FloatingActionButton.extended(
        onPressed: () => _buildTravelPath(loadAll: true),
        label: const Text("모든 사진 분석하기"),
        icon: const Icon(Icons.photo_library),
        backgroundColor: Colors.orangeAccent,
      ),
    );
  }

  Widget _buildStatusCard() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]),
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
            LinearProgressIndicator(value: _totalCount == 0 ? null : (_processedCount / _totalCount), backgroundColor: Colors.grey[700], color: Colors.orangeAccent),
            const SizedBox(height: 10),
            Text("$_processedCount / $_totalCount 장", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
      ),
    );
  }

  // 🔥 딱 3장만 보이면서 현재 사진이 무조건 정중앙에 고정되는 쾌속 스크롤바
  Widget _buildVerticalFastScroller() {
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();

    return Container(
      height: 180, // 아이템(60px) * 3장 = 정확히 180px
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(30)),
      child: ShaderMask(
        shaderCallback: (Rect bounds) => const LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
          stops: [0.0, 0.15, 0.85, 1.0], 
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: Listener(
          onPointerDown: (_) => _isRightDragging = true,
          onPointerUp: (_) => _isRightDragging = false,
          onPointerCancel: (_) => _isRightDragging = false,
          child: RawScrollbar(
            controller: _verticalScrollController,
            thumbVisibility: true, interactive: true, thickness: 6.0, radius: const Radius.circular(10), thumbColor: Colors.white70,
            child: ListView.builder(
              controller: _verticalScrollController,
              padding: const EdgeInsets.symmetric(vertical: 60), // 🔥 상하단에 60px 패딩을 주어 첫/마지막 사진도 정중앙에 올 수 있게 세팅
              itemExtent: 60.0, // 모든 사진의 높이를 60px로 고정하여 수학적 오차 제거
              itemCount: allPhotos.length,
              itemBuilder: (context, idx) {
                final asset = allPhotos[idx].originalAsset;
                if (asset == null) return const SizedBox.shrink();
                
                return GestureDetector(
                  onTap: () => _pageController?.animateToPage(idx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut),
                  child: SizedBox(
                    height: 60.0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                      child: ClipOval(child: AspectRatio(aspectRatio: 1, child: AssetEntityImage(asset, fit: BoxFit.cover, isOriginal: false, thumbnailSize: const pm.ThumbnailSize(60, 60)))),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
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
        key: ValueKey(_selectedTripIndex), 
        controller: _pageController,
        itemCount: allPhotos.length,
        itemBuilder: (context, idx) {
          final asset = allPhotos[idx].originalAsset;
          if (asset == null) return const SizedBox.shrink();

          return AnimatedBuilder(
            animation: _pageController!,
            builder: (context, child) {
              double value = 1.0;
              if (_pageController!.hasClients && _pageController!.positions.length == 1 && _pageController!.position.haveDimensions) {
                value = _pageController!.page! - idx;
                value = (1 - (value.abs() * 0.3)).clamp(0.0, 1.0);
              }
              return Center(
                child: SizedBox(
                  height: Curves.easeOut.transform(value) * 100, width: Curves.easeOut.transform(value) * 100,
                  child: Opacity(opacity: value.clamp(0.4, 1.0), child: child),
                ),
              );
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)]),
              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: AssetEntityImage(asset, fit: BoxFit.cover))
            ),
          );
        },
      ),
    );
  }
}
