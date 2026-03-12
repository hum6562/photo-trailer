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
  
  // 🔥 PageController로 변경: 뷰포트를 줄여서 양옆 사진이 살짝 보이게 (필름 효과)
  final PageController _pageController = PageController(viewportFraction: 0.25);
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
    _pageController.addListener(_onPageScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _buildTravelPath(loadAll: false));
  }

  // 🔥 스크롤 시 카메라 동기화
  void _onPageScroll() {
    if (_selectedTripIndex == null || _isLoading || !_pageController.hasClients) return;
    
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    if (allPhotos.isEmpty) return;

    double page = _pageController.page ?? 0;
    int currentIndex = page.round().clamp(0, allPhotos.length - 1);
    
    // 너무 잦은 지도 업데이트 방지
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

    // 🔥 여기서 중요도를 계산해서 정렬합니다 (여행 우선, 그 다음 사진 갯수)
    analyzedTrips.sort((a, b) {
      if (a.isTrip && !b.isTrip) return -1; // 여행 우선
      if (!a.isTrip && b.isTrip) return 1;
      return b.totalPhotoCount.compareTo(a.totalPhotoCount); // 장수 많은 순
    });

    Set<Marker> overviewMarkers = {};
    
    // 🔥 화면에 핀이 너무 꽉 차지 않게 상위 15개(여행 위주)만 지도에 표시합니다.
    final displayTrips = analyzedTrips.take(15).toList();

    for (int i = 0; i < displayTrips.length; i++) {
      final trip = displayTrips[i];
      if (trip.places.isEmpty) continue;
      
      // 🔥 첫 장소가 아니라, 사진이 '가장 많은 장소(메인 목적지)'에 핀을 꽂음
      final mainPlace = trip.mainPlace;
      final bestPhoto = mainPlace.representative.originalAsset;
      
      if (bestPhoto != null) {
        Color borderColor = trip.isTrip ? Colors.orangeAccent : Colors.white;
        
        overviewMarkers.add(Marker(
          markerId: MarkerId("ov_$i"),
          position: mainPlace.centroid,
          icon: await _getPhotoMarker(bestPhoto, borderColor, count: trip.totalPhotoCount),
          onTap: () => _onTripSelected(analyzedTrips.indexOf(trip)), // 전체 리스트에서의 인덱스 전달
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

  Future<void> _onTripSelected(int index) async {
    setState(() { _selectedTripIndex = index; _isLoading = true; });
    
    // 새 여행을 누르면 파노라마 리스트 위치를 맨 처음(0)으로 초기화
    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }

    final trip = _trips[index];
    
    if (trip.isTrip && trip.path.length > 1) {
      _polylines = { Polyline(polylineId: PolylineId("p$index"), points: trip.path, color: Colors.orange, width: 5) };
    } else {
      _polylines = {};
    }
    
    Set<Marker> detailMarkers = {};
    for (int i = 0; i < trip.places.length; i++) {
      final asset = trip.places[i].representative.originalAsset;
      if (asset != null) {
        detailMarkers.add(Marker(
          markerId: MarkerId("pl$i"),
          position: trip.places[i].centroid,
          icon: await _getPhotoMarker(asset, Colors.white), 
        ));
      }
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

  // 🔥 count 파라미터 추가하여 우측 상단에 갯수 배지 달기
  Future<BitmapDescriptor> _getPhotoMarker(pm.AssetEntity entity, Color borderColor, {int? count}) async {
    final data = await entity.thumbnailDataWithSize(const pm.ThumbnailSize(100, 100));
    if (data == null) return BitmapDescriptor.defaultMarker;
    final codec = await ui.instantiateImageCodec(data);
    final fi = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 60.0; 
    
    // 사진 그리기
    canvas.drawCircle(const Offset(size/2, size/2), size/2, Paint()..color = borderColor);
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(4, 4, size-8, size-8)));
    canvas.drawImageRect(fi.image, Rect.fromLTWH(0, 0, fi.image.width.toDouble(), fi.image.height.toDouble()), const Rect.fromLTWH(0, 0, size, size), Paint());
    
    // 🔥 배지 그리기 (count가 있을 때만)
    if (count != null && count > 0) {
      String text = count > 99 ? "99+" : count.toString();
      final textPainter = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      
      // 빨간색 원 배지
      double badgeRadius = 12.0;
      Offset badgeCenter = const Offset(size - 12, 12);
      canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = Colors.redAccent);
      
      // 텍스트 위치 중앙 정렬
      textPainter.paint(canvas, Offset(badgeCenter.dx - textPainter.width/2, badgeCenter.dy - textPainter.height/2));
    }

    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
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
          
          if (_selectedTripIndex != null) Positioned(bottom: 20, left: 0, right: 0, child: _buildTripFilmStrip()),
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

  // 🔥 영화 필름처럼 스르륵 넘어가는 UI (AnimatedBuilder 활용)
  Widget _buildTripFilmStrip() {
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    
    return SizedBox(
      height: 120, // 높이를 작게 줄여서 하단에 깔리게 함
      child: PageView.builder(
        controller: _pageController,
        itemCount: allPhotos.length,
        itemBuilder: (context, idx) {
          final asset = allPhotos[idx].originalAsset;
          if (asset == null) return const SizedBox.shrink();

          return AnimatedBuilder(
            animation: _pageController,
            builder: (context, child) {
              double value = 1.0;
              if (_pageController.position.haveDimensions) {
                value = _pageController.page! - idx;
                // 멀어질수록 크기를 줄임 (0.7배까지)
                value = (1 - (value.abs() * 0.3)).clamp(0.0, 1.0);
              }
              return Center(
                child: SizedBox(
                  // 선택된 건 100, 양옆은 70 정도로 작아짐
                  height: Curves.easeOut.transform(value) * 100,
                  width: Curves.easeOut.transform(value) * 100,
                  child: Opacity(
                    // 선택된 건 100% 선명, 양옆은 반투명(40%)
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
